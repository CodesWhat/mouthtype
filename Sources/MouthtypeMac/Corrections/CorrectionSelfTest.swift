import AppKit
import ApplicationServices
import Foundation
import MouthtypeCore

/// `--correction-selftest`: opens a window with an editable text view, registers a "paste" into it, edits one word
/// the way typing would, and checks that the watcher read the change over the real Accessibility API, the learner
/// proposed the fix, the card showed, a synthetic click on Save landed and a temporary dictionary gained the rule.
/// A second pass rewrites the text and expects no offer. Uses a temporary dictionary, ledger and database; the real
/// ones are never opened.
@MainActor
enum CorrectionSelfTest {
    static let flag = "--correction-selftest"

    static func isRequested(in arguments: [String]) -> Bool { arguments.contains(flag) }

    private static var failures: [String] = []

    private static func report(_ line: String) {
        Log.selftest.info("correction-selftest \(line, privacy: .public)")
        print("correction-selftest \(line)")
        fflush(stdout)
    }

    private static func check(_ name: String, _ passed: Bool) {
        report("\(passed ? "ok" : "FAIL") \(name)")
        if !passed { failures.append(name) }
    }

    private static func wait(timeout: TimeInterval, until condition: @MainActor () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return condition()
    }

    static func run() async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mouthtype-correction-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dictionaryURL = directory.appendingPathComponent("dictionary.json")
        report("temporary dictionary \(dictionaryURL.path)")
        try? #"[{ "heard": "mouth type", "written": "Mouthtype", "starred": true }]"#.write(to: dictionaryURL, atomically: true, encoding: .utf8)

        guard let store = try? TranscriptStore(url: directory.appendingPathComponent("mouthtype.sqlite")) else {
            report("FAIL temporary store")
            try? FileManager.default.removeItem(at: directory)
            NSApp.terminate(nil)
            return
        }
        let clock = SystemDictationClock()
        let dictionary = FileVocabulary(url: dictionaryURL)
        let pill = PillController(level: { .silence })
        let cards = DeliveryCardController()
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        let presenter = DeliveryCardPresenter(surface: cards, clipboard: SystemClipboard(), clock: clock)
        cards.onAction = { [weak presenter] action in presenter?.perform(action) }
        cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }
        let reader = AccessibilityFieldReader()
        let watcher = CorrectionWatcher(
            reader: reader, dictionary: dictionary, ledger: CorrectionLedger(url: directory.appendingPathComponent("corrections.json")),
            store: CorrectionStoreWriter(store: store), cards: presenter, clock: clock, input: { nil }, isEnabled: { true },
            canOffer: { true }
        )
        var trace: [String] = []
        watcher.onTrace = { line in
            trace.append(line)
            report("watcher: \(line)")
        }

        NSApp.setActivationPolicy(.accessory)
        let scroll = NSTextView.scrollableTextView()
        guard let textView = scroll.documentView as? NSTextView else { return }
        textView.isEditable = true
        textView.font = .systemFont(ofSize: 15)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 400, width: 520, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Mouthtype correction self-test"
        window.isReleasedWhenClosed = false
        window.contentView = scroll
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()
        window.makeFirstResponder(textView)

        var attempts = 0
        let focused = await wait(timeout: 8) {
            // An accessory app is not brought forward by one request; ask again until the system agrees.
            if !NSApp.isActive || !window.isKeyWindow {
                attempts += 1
                if attempts % 10 == 4 {
                    // Ask LaunchServices to bring this running app forward, as a Dock click would.
                    let configuration = NSWorkspace.OpenConfiguration()
                    configuration.activates = true
                    NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                }
                NSApp.activate()
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(textView)
            }
            let probe = reader.probe()
            return probe.pid == ProcessInfo.processInfo.processIdentifier && probe.element != nil
        }
        let seen = reader.probe()
        report(
            "accessibility trusted \(AXIsProcessTrusted()), own pid \(ProcessInfo.processInfo.processIdentifier), frontmost pid \(seen.pid.map(String.init) ?? "none"), focused element \(seen.element != nil), app active \(NSApp.isActive), window key \(window.isKeyWindow)"
        )
        check("the test window's text view has Accessibility focus", focused)
        guard focused else { return finish(window, directory) }

        // Pass one: a fix.
        let pasted = "Hove said the new build is ready for review today"
        _ = try? store.begin(DictationStart(id: "selftest-fix"))
        textView.string = pasted
        let target = AccessibilityFocusReader().snapshot()
        check("the focused element is a text area or field", target.role == "AXTextArea" || target.role == "AXTextField")
        watcher.pasted(pasted, dictationID: "selftest-fix", target: target)
        check("the watcher is watching", watcher.isWatching)
        try? await Task.sleep(for: .milliseconds(900))

        let range = (textView.string as NSString).range(of: "Hove")
        textView.insertText("Hov", replacementRange: range)
        let axValue = target.element.flatMap { AccessibilityFocusReader().fieldValue(of: $0) }
        check("the real Accessibility value shows the edit", axValue?.hasPrefix("Hov said") == true)

        let shownAt = Date()
        let shown = await wait(timeout: 10) { presenter.state?.card.kind == .rememberSpelling }
        check("the card showed", shown)
        guard shown, let card = presenter.state?.card else { return finish(window, directory) }
        report("card appeared \(String(format: "%.1f", Date().timeIntervalSince(shownAt))) s after the edit, window \(cards.panel.windowNumber)")
        check("the learner proposed Hove -> Hov", card.pair == SpellingPair(heard: "Hove", corrected: "Hov"))
        check("the card header and buttons", card.header == "Remember this spelling?" && card.actions == [.save, .notNow])
        try? await Task.sleep(for: .seconds(5))

        guard let save = cards.screenCenter(of: .save) else { return finish(window, directory) }
        let frontBefore = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        click(at: quartz(save))
        report("synthetic click on Save at \(Int(save.x)),\(Int(save.y))")
        let confirmed = await wait(timeout: 2) { presenter.state?.copied == true }
        check("Save fired and the card confirmed in place", confirmed)
        check("the click left the frontmost app alone", NSWorkspace.shared.frontmostApplication?.bundleIdentifier == frontBefore)
        check("the card then left", await wait(timeout: 3) { presenter.state == nil })

        let contents = (try? String(contentsOf: dictionaryURL, encoding: .utf8)) ?? ""
        report("dictionary file now:\n\(contents)")
        check("the dictionary gained Hove -> Hov", dictionary.dictionary().contains(DictionaryRule(heard: "Hove", written: "Hov")))
        check("the existing entry was kept as written", contents.contains(#"{ "heard": "mouth type", "written": "Mouthtype", "starred": true }"#))
        try? await Task.sleep(for: .milliseconds(300))
        let rows = (try? store.corrections(dictationID: "selftest-fix")) ?? []
        check("the store recorded one accepted offer", rows.count == 1 && rows.first?.accepted == true)

        // Pass two: a rewrite.
        let before = trace.count
        let second = "Please send Priya the updated agenda before the end of the day"
        _ = try? store.begin(DictationStart(id: "selftest-rewrite"))
        textView.string = second
        let target2 = AccessibilityFocusReader().snapshot()
        watcher.pasted(second, dictationID: "selftest-rewrite", target: target2)
        try? await Task.sleep(for: .milliseconds(900))
        textView.insertText("Totally different sentence about gardening and soil", replacementRange: NSRange(location: 0, length: (textView.string as NSString).length))
        let evaluated = await wait(timeout: 8) { trace.dropFirst(before).contains { $0.hasPrefix("evaluated") } }
        check("the rewrite was evaluated", evaluated)
        try? await Task.sleep(for: .seconds(1.5))
        check("nothing was proposed for the rewrite", presenter.state == nil && trace.dropFirst(before).contains("evaluated: 0 proposals, 0 reverted"))
        check("the rewrite recorded no offer", ((try? store.corrections(dictationID: "selftest-rewrite")) ?? []).isEmpty)
        finish(window, directory)
    }

    private static func finish(_ window: NSWindow, _ directory: URL) {
        report(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
        window.close()
        try? FileManager.default.removeItem(at: directory)
        NSApp.terminate(nil)
    }

    private static func quartz(_ point: CGPoint) -> CGPoint {
        CGPoint(x: point.x, y: (NSScreen.screens.first?.frame.height ?? 0) - point.y)
    }

    private static func click(at point: CGPoint) {
        CGWarpMouseCursorPosition(point)
        for type in [CGEventType.mouseMoved, .leftMouseDown, .leftMouseUp] {
            CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: .left)?.post(tap: .cghidEventTap)
            usleep(150_000)
        }
    }
}
