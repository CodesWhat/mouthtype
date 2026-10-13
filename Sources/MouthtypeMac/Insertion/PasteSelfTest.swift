import AppKit
import ApplicationServices
import Foundation
import MouthtypeCore

/// `--paste-selftest`: opens a window with an editable text view, a read-only one and a button, and runs the real
/// inserter against each with real Cmd+V events. Proves a paste lands, is read, is verified and the clipboard comes
/// back; that a button is refused with the card raised; and that a target which ignores the paste ends as "not
/// landed" with the card raised. Saves and restores the user's clipboard. Touches no database or dictionary.
@MainActor
enum PasteSelfTest {
    static let flag = "--paste-selftest"

    static func isRequested(in arguments: [String]) -> Bool { arguments.contains(flag) }

    private static var failures: [String] = []

    private static func report(_ line: String) {
        Log.selftest.info("paste-selftest \(line, privacy: .public)")
        print("paste-selftest \(line)")
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
            try? await Task.sleep(for: .milliseconds(50))
        }
        return condition()
    }

    static func run() async {
        let general = SystemPasteboard(.general)
        let userClipboard = general.snapshot()
        report("saved the real clipboard (\(userClipboard.items.count) items); it is restored at the end")
        let sentinel = "MT-SELFTEST-USER-CLIPBOARD"

        let resolved = SystemPasteKeyResolver().pasteKeyCode()
        report("resolved V key code for the current layout: \(resolved.map(String.init) ?? "none")")
        check("a V key resolves", resolved != nil)

        NSApp.setActivationPolicy(.accessory)
        installPasteMenu()
        let editable = makeTextView(editable: true, string: "Start: ")
        let readOnly = makeTextView(editable: false, string: "Read only text that ignores the paste.")
        let button = NSButton(title: "Not a text field", target: nil, action: nil)
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 520, height: 330), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Mouthtype paste self-test"
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 330))
        editable.scroll.frame = NSRect(x: 10, y: 220, width: 500, height: 100)
        readOnly.scroll.frame = NSRect(x: 10, y: 110, width: 500, height: 100)
        button.frame = NSRect(x: 10, y: 60, width: 200, height: 32)
        for view in [editable.scroll, readOnly.scroll, button] as [NSView] { content.addSubview(view) }
        window.contentView = content
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        let cards = DeliveryCardController()
        let pill = PillController(level: { .silence })
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        let presenter = DeliveryCardPresenter(surface: cards, clipboard: SystemClipboard(), clock: SystemDictationClock())
        cards.onAction = { [weak presenter] action in presenter?.perform(action) }
        cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }

        let inserter = TextInserter(syntheticStamp: SyntheticEvents.stamp, inputGeneration: { 0 })
        var verdicts: [PasteVerification] = []
        inserter.observeVerification { verdicts.append($0) }

        func focus(_ responder: NSResponder, role: String) async -> Bool {
            var attempts = 0
            return await wait(timeout: 8) {
                if !NSApp.isActive || !window.isKeyWindow || window.firstResponder !== responder {
                    attempts += 1
                    if attempts % 10 == 4 {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                    }
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(responder)
                }
                let snapshot = AccessibilityFocusReader().snapshot()
                return snapshot.pid == ProcessInfo.processInfo.processIdentifier && snapshot.role == role
            }
        }

        report("accessibility trusted \(AXIsProcessTrusted()), own pid \(ProcessInfo.processInfo.processIdentifier)")

        // 1. A real paste.
        general.write(sentinel, markers: [])
        let ready = await focus(editable.view, role: "AXTextArea")
        check("the editable text view has Accessibility focus", ready)
        if ready {
            editable.view.setSelectedRange(NSRange(location: editable.view.string.utf16.count, length: 0))
            verdicts = []
            let start = Date()
            let result = await inserter.deliver("pasted by the self test", startFocus: nil)
            report("deliver returned in \(Int(Date().timeIntervalSince(start) * 1000)) ms, method \(result.method), verification id \(result.verificationID.map(String.init) ?? "none")")
            check("the paste was posted", result.method == .paste && result.outcome == .unknown)
            check("deliver did not wait for the read-back", verdicts.isEmpty)
            let landed = await wait(timeout: 3) { editable.view.string.contains("pasted by the self test") }
            check("the text landed in the text view", landed)
            await inserter.waitForVerification()
            check("the read-back ended with one verdict", verdicts.count == 1)
            check("the verdict is confirmed", verdicts.first?.verdict == .confirmed)
            report("receipt \(verdicts.first?.receiptMs.map { "\($0) ms after the chord" } ?? "none")")
            check("a receipt was observed", verdicts.first?.receiptMs != nil)
            if let onMain = PasteCallbackProbe.shared.lastCallbackWasOnMain {
                report("the pasteboard called the promise back \(onMain ? "on" : "off") the main thread")
            } else {
                report("the pasteboard never called the promise back")
            }
            let restored = await wait(timeout: 3) { !inserter.isRestorePending }
            check("the restore ran", restored)
            check("the clipboard is back to what it was", general.currentString() == sentinel)
        }

        // 2. A target that can't take text.
        general.write(sentinel, markers: [])
        let buttonFocused = await focus(button, role: "AXButton")
        check("the button has Accessibility focus", buttonFocused)
        if buttonFocused {
            let result = await inserter.deliver("not for a button", startFocus: nil)
            check("the paste was refused", result.method == .clipboardOnly && result.outcome == .unknown && inserter.isRestorePending == false)
            check("the transcript is on the clipboard", general.currentString() == "not for a button")
            if let card = DeliveryCard.forDelivery(result, transcript: "not for a button") { presenter.present(card) }
            check("the card is raised with Copy", presenter.state?.card.kind == .nowhere && presenter.state?.card.actions == [.copy])
            try? await Task.sleep(for: .milliseconds(500))
            presenter.dismiss()
        }

        // 3. A target that ignores the paste.
        general.write(sentinel, markers: [])
        let readOnlyFocused = await focus(readOnly.view, role: "AXTextArea")
        check("the read-only text view has Accessibility focus", readOnlyFocused)
        if readOnlyFocused {
            verdicts = []
            let before = readOnly.view.string
            let result = await inserter.deliver("this will not land", startFocus: nil)
            check("the paste was posted", result.method == .paste)
            await inserter.waitForVerification()
            check("the text view did not change", readOnly.view.string == before)
            check("the verdict is not landed", verdicts.first?.verdict == .notLanded)
            if let verdict = verdicts.first?.verdict, let card = DeliveryCard.forVerdict(verdict, transcript: result.finalText) {
                presenter.present(card)
            }
            let card = presenter.state?.card
            check("the card is raised with the headline, detail and Copy",
                  card?.header == "Paste didn't land\nThe field didn't change" && card?.actions == [.copy] && card?.transcript == result.finalText)
            try? await Task.sleep(for: .milliseconds(700))
            await saveShot(window: cards.panel.windowNumber, name: "card-paste-not-landed.png")
            presenter.dismiss()
        }

        // Done: let any restore finish, then give the real clipboard back.
        let settled = await wait(timeout: 10) { !inserter.isRestorePending }
        check("no restore is left pending", settled)
        general.restore(userClipboard)
        report("restored the real clipboard")
        report(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
        window.close()
        NSApp.terminate(nil)
    }

    private static func makeTextView(editable: Bool, string: String) -> (scroll: NSScrollView, view: NSTextView) {
        let scroll = NSTextView.scrollableTextView()
        let view = scroll.documentView as! NSTextView
        view.isEditable = editable
        view.isSelectable = true
        view.font = .systemFont(ofSize: 15)
        view.string = string
        return (scroll, view)
    }

    /// A key window needs an Edit menu with Paste for Cmd+V to reach a text view; an accessory app has none.
    private static func installPasteMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item.submenu = edit
        NSApp.mainMenu = main
    }

    private static func saveShot(window: Int, name: String) async {
        let directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("build/pill-shots/classic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window), url.path]
        do {
            try process.run()
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } catch {
            report("screencapture failed to start: \(error)")
        }
        let saved = (try? url.checkResourceIsReachable()) ?? false
        check("the not-landed card screenshot was saved", saved)
        report("screenshot \(url.path)")
    }
}
