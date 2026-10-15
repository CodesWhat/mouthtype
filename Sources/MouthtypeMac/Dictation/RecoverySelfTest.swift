import AppKit
import ApplicationServices
import Foundation
import MouthtypeCore

/// `--recovery-selftest`: proves the "nothing is lost" paths end to end against a temporary database and archive.
/// (1) Seeds rows a crash would leave, runs the launch scan, raises the Recover card, recovers through the real engine
/// and checks the row ends terminal and a second scan offers nothing. (2) Two back-to-back dictations where the second
/// starts while the first is processing, delivered in order into the self-test's own text view with the real inserter.
/// (3) The length limit with short injected durations. (4) A simulated microphone loss from a background thread, then
/// Insert. Speech comes from `say`; the capture is synthetic. Saves and restores the user's clipboard; the real
/// database, archive and dictionary are never opened.
@MainActor
enum RecoverySelfTest {
    static let flag = "--recovery-selftest"
    struct Options {}

    static func options(in arguments: [String]) -> Options? { arguments.contains(flag) ? Options() : nil }

    private static var failures: [String] = []

    private static func report(_ line: String) {
        Log.selftest.info("recovery-selftest \(line, privacy: .public)")
        print("recovery-selftest \(line)")
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

    // MARK: Synthetic pieces

    /// A microphone that plays back scripted speech: each recording gets the next clip.
    @MainActor
    private final class SyntheticCapture: DictationCapturing {
        var isPrepared = true
        var script: [[Float]] = []
        var onInterrupted: (@MainActor () -> Void)?
        private(set) var starts = 0
        private(set) var stops = 0
        private var current: [Float] = []
        private var startedAt = Date()

        func start(keyDownAtNanos: UInt64) async throws {
            starts += 1
            current = script.isEmpty ? [] : script.removeFirst()
            startedAt = Date()
        }

        func stop() async throws -> CapturedAudio {
            stops += 1
            return CapturedAudio(
                samples: current, sampleRate: 16_000, deviceUID: nil, deviceName: "synthetic", deviceTransport: "synthetic",
                firstSampleMs: 0, firstNonzeroMs: 0, captureStartMs: 0, audioMs: Double(current.count) / 16
            )
        }

        func partialSamples(from offset: Int) async -> [Float] {
            let upTo = min(current.count, Int(Date().timeIntervalSince(startedAt) * 16_000))
            return offset < upTo ? Array(current[offset..<upTo]) : []
        }

        func cancel() async {}

        /// The input goes away, announced from a thread of its own the way Core Audio does it.
        func simulateDisconnect() {
            let hop = onInterrupted.map(CaptureInterruption.hop)
            DispatchQueue.global().async { hop?() }
        }
    }

    private final class SilentSounds: SoundPlayer {
        func playStart() {}
        func playStop() {}
        func playLock() {}
        func playError() {}
    }

    private static func speak(_ text: String, in directory: URL, name: String) async -> [Float] {
        let url = directory.appendingPathComponent("\(name).aiff")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", url.path, text]
        do {
            try process.run()
            await withCheckedContinuation { continuation in
                process.terminationHandler = { _ in continuation.resume() }
            }
        } catch {
            report("say failed to start: \(error)")
        }
        return (try? AudioLoading.loadSamples(from: url)) ?? []
    }

    private static func saveShot(window: Int, name: String) async {
        let directory = Bundle.main.bundleURL.deletingLastPathComponent()
            .appendingPathComponent("pill-shots/classic", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
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
        check("screenshot \(name) was saved", (try? url.checkResourceIsReachable()) ?? false)
        report("screenshot \(url.path)")
    }

    private static func installPasteMenu() {
        let main = NSMenu()
        let item = NSMenuItem()
        main.addItem(item)
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        item.submenu = edit
        NSApp.mainMenu = main
    }

    private static func waitForEngine(_ host: EngineHost) async -> Bool {
        let deadline = Date().addingTimeInterval(600)
        while Date() < deadline {
            switch host.state {
            case .ready: return true
            case .failed: return false
            case .loading: try? await Task.sleep(for: .milliseconds(200))
            }
        }
        return false
    }

    private static func seed(
        store: TranscriptStore, archive: AudioArchive, id: String, ago: TimeInterval, samples: [Float]?, partial: Bool = false
    ) throws {
        try store.begin(DictationStart(id: id, startedAt: Date().addingTimeInterval(-ago)))
        guard let samples else { return }
        if partial {
            try archive.appendPartial(samples: samples, id: id)
            return
        }
        let entry = try archive.write(samples: samples, id: id)
        try store.recordCapture(id, CaptureRecord(
            audioMs: samples.count / 16, audioPath: entry.url.path, audioExpiresAt: Date().addingTimeInterval(86_400)
        ))
    }

    // MARK: Run

    static func run(options: Options, engineHost: EngineHost) async {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("mouthtype-recovery-selftest-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        report("temporary store and archive in \(directory.path)")
        guard let store = try? TranscriptStore(url: directory.appendingPathComponent("mouthtype.sqlite")) else {
            report("FAIL temporary store")
            NSApp.terminate(nil)
            return
        }
        let archive = AudioArchive(supportDirectory: directory)
        let clock = SystemDictationClock()

        report("waiting for the engine")
        guard await waitForEngine(engineHost) else {
            report("FAIL the engine did not load")
            NSApp.terminate(nil)
            return
        }
        let recoverText = await speak("Sounds good, I'll send it over now.", in: directory, name: "recover")
        let partialText = await speak("Please move the standup to three o'clock tomorrow.", in: directory, name: "partial")
        let first = await speak("Remember to water the plants.", in: directory, name: "first")
        let second = await speak("The meeting starts at noon.", in: directory, name: "second")
        let third = await speak("Thanks for the quick reply.", in: directory, name: "third")
        check("speech clips were generated", [recoverText, partialText, first, second, third].allSatisfy { $0.count > 16_000 })

        NSApp.setActivationPolicy(.accessory)
        let general = SystemPasteboard(.general)
        let userClipboard = general.snapshot()
        report("saved the real clipboard (\(userClipboard.items.count) items); it is restored at the end")

        let pill = PillController(level: { .silence })
        let cards = DeliveryCardController()
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        let presenter = DeliveryCardPresenter(surface: cards, clipboard: SystemClipboard(), clock: clock)
        cards.onAction = { [weak presenter] action in presenter?.perform(action) }
        cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }

        var pipeline = DictationPipeline(
            store: TranscriptStoreWriter(store: store), archive: archive, engine: HostEngine(host: engineHost), clock: clock
        )
        pipeline.settings = { CleanupSettings() }

        // MARK: 1. Crash recovery

        report("-- 1. crash recovery")
        let newest = "A-" + UUID().uuidString, older = "B-" + UUID().uuidString
        let lost = "C-" + UUID().uuidString, ancient = "D-" + UUID().uuidString
        do {
            try seed(store: store, archive: archive, id: ancient, ago: 3 * 86_400, samples: recoverText)
            try seed(store: store, archive: archive, id: older, ago: 900, samples: first)
            try seed(store: store, archive: archive, id: lost, ago: 300, samples: nil)
            try seed(store: store, archive: archive, id: newest, ago: 125, samples: recoverText)
        } catch {
            check("seeded the interrupted rows (\(error))", false)
        }
        // Older than this launch's start, so the scan sees them.
        let recovery = CrashRecovery(
            store: store, archive: archive, pipeline: pipeline, cards: presenter, pill: pill, clock: clock,
            launchedAt: Date().addingTimeInterval(1)
        )
        let scan = await recovery.offerIfNeeded()
        check("the scan found the newest row", scan?.newest?.id == newest)
        check("one older recoverable row was set aside", scan?.olderCount == 1)
        check("the row with no audio was counted lost", scan?.lostCount == 1)
        let offer = presenter.state?.card
        check("the Recover card is up", offer?.kind == .recoverOffer && offer?.actions == [.recover, .discard])
        report("card header: \(offer?.header.replacingOccurrences(of: "\n", with: " | ") ?? "none")")
        check("the headline and detail lines read right",
              offer?.header.hasPrefix("Recover your last dictation?\n2 seconds, 2 minutes ago") == true
                || offer?.header.hasPrefix("Recover your last dictation?\n") == true)
        check("the older one is noted", offer?.header.hasSuffix("and 1 older one in Saved Recordings") == true)
        check("the newest row is ended as failed/interrupted so it isn't offered twice",
              (try? store.dictation(id: newest))?.status == .failed && (try? store.dictation(id: newest))?.errorMessage == "interrupted")
        check("the row with no audio is failed/interrupted", (try? store.dictation(id: lost))?.errorMessage == "interrupted")
        check("the older row is failed/interrupted with its audio kept",
              (try? store.dictation(id: older))?.status == .failed && FileManager.default.fileExists(atPath: archive.url(for: older).path))
        check("a row from days ago is left alone", (try? store.dictation(id: ancient))?.status == .recorded)
        try? await Task.sleep(for: .milliseconds(700))
        await saveShot(window: cards.panel.windowNumber, name: "card-recover.png")

        presenter.perform(.recover)
        let recovered = await wait(timeout: 60) { presenter.state?.card.kind == .recovered }
        check("Recover raised the result card", recovered)
        let recoveredText = presenter.state?.card.transcript ?? ""
        report("recovered text: \(recoveredText)")
        check("the recovered text is not empty", !recoveredText.isEmpty)
        check("the result card offers Copy only", presenter.state?.card.actions == [.copy])
        let row = try? store.dictation(id: newest)
        check("the recovered row ended terminal (inserted, with its text)", row?.status == .inserted && row?.finalText == recoveredText)
        presenter.dismiss()

        let again = CrashRecovery(
            store: store, archive: archive, pipeline: pipeline, cards: presenter, pill: pill, clock: clock,
            launchedAt: Date().addingTimeInterval(1)
        )
        let second1 = await again.offerIfNeeded()
        check("a second pass offers nothing", second1?.newest == nil && presenter.state == nil)

        // A recording the app died in the middle of: only the in-progress copy exists.
        let halfway = "E-" + UUID().uuidString
        try? seed(store: store, archive: archive, id: halfway, ago: 40, samples: partialText, partial: true)
        check("the in-progress copy is on disk", FileManager.default.fileExists(atPath: archive.partialURL(for: halfway).path))
        let third1 = CrashRecovery(
            store: store, archive: archive, pipeline: pipeline, cards: presenter, pill: pill, clock: clock,
            launchedAt: Date().addingTimeInterval(1)
        )
        let partialScan = await third1.offerIfNeeded()
        check("a row with only an in-progress copy is offered", partialScan?.newest?.id == halfway && partialScan?.newest?.isPartial == true)
        presenter.perform(.recover)
        let partialRecovered = await wait(timeout: 60) { presenter.state?.card.kind == .recovered }
        check("the in-progress copy recovered to text", partialRecovered && !(presenter.state?.card.transcript ?? "").isEmpty)
        report("recovered from the in-progress copy: \(presenter.state?.card.transcript ?? "")")
        check("the archived WAV replaced the in-progress copy",
              FileManager.default.fileExists(atPath: archive.url(for: halfway).path)
                && !FileManager.default.fileExists(atPath: archive.partialURL(for: halfway).path))
        presenter.dismiss()

        // Discard ends the row cancelled.
        let toDiscard = "F-" + UUID().uuidString
        try? seed(store: store, archive: archive, id: toDiscard, ago: 20, samples: second)
        let fourth = CrashRecovery(
            store: store, archive: archive, pipeline: pipeline, cards: presenter, pill: pill, clock: clock,
            launchedAt: Date().addingTimeInterval(1)
        )
        await fourth.offerIfNeeded()
        presenter.perform(.discard)
        let discarded = await wait(timeout: 5) { (try? store.dictation(id: toDiscard))?.status == .cancelled }
        check("Discard ended the row cancelled with its audio kept",
              discarded && FileManager.default.fileExists(atPath: archive.url(for: toDiscard).path))

        // MARK: Window for the delivery parts

        let scroll = NSTextView.scrollableTextView()
        let textView = scroll.documentView as! NSTextView
        textView.isEditable = true
        textView.isSelectable = true
        textView.font = .systemFont(ofSize: 15)
        textView.string = "Start: "
        installPasteMenu()
        let window = NSWindow(
            contentRect: NSRect(x: 200, y: 300, width: 520, height: 200), styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "Mouthtype recovery self-test"
        window.isReleasedWhenClosed = false
        scroll.frame = NSRect(x: 10, y: 10, width: 500, height: 180)
        window.contentView = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 200))
        window.contentView?.addSubview(scroll)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate()

        func focusTextView() async -> Bool {
            var attempts = 0
            return await wait(timeout: 8) {
                if !NSApp.isActive || !window.isKeyWindow || window.firstResponder !== textView {
                    attempts += 1
                    if attempts % 10 == 4 {
                        let configuration = NSWorkspace.OpenConfiguration()
                        configuration.activates = true
                        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
                    }
                    NSApp.activate()
                    window.makeKeyAndOrderFront(nil)
                    window.makeFirstResponder(textView)
                }
                let snapshot = AccessibilityFocusReader().snapshot()
                return snapshot.pid == ProcessInfo.processInfo.processIdentifier && snapshot.role == "AXTextArea"
            }
        }

        report("accessibility trusted \(AXIsProcessTrusted()), own pid \(ProcessInfo.processInfo.processIdentifier)")
        let focused = await focusTextView()
        check("the text view has Accessibility focus", focused)
        guard focused else { return finish(window: window, general: general, snapshot: userClipboard, directory: directory) }
        textView.setSelectedRange(NSRange(location: textView.string.utf16.count, length: 0))

        let inserter = TextInserter(
            syntheticStamp: SyntheticEvents.stamp, inputGeneration: { 0 }, restrictedToPID: ProcessInfo.processInfo.processIdentifier
        )
        func makeController(
            _ capture: SyntheticCapture, limits: DictationController.Limits = .standard
        ) -> DictationController {
            DictationController(
                capture: capture, engine: HostEngine(host: engineHost), pipeline: pipeline, inserter: inserter, pill: pill,
                sounds: SilentSounds(), clock: clock, cards: presenter, limits: limits
            )
        }
        func latestAudioID() -> String? {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: archive.directory, includingPropertiesForKeys: [.contentModificationDateKey]
            )) ?? []
            return files.filter { $0.pathExtension == "wav" && !$0.lastPathComponent.hasSuffix(".partial.wav") }
                .max { (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
                    < (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast }?
                .deletingPathExtension().lastPathComponent
        }
        func index(of word: String) -> String.Index? { textView.string.lowercased().range(of: word)?.lowerBound }

        // MARK: 2. Queue

        report("-- 2. queue")
        general.write("MT-SELFTEST-USER-CLIPBOARD", markers: [])
        let capture2 = SyntheticCapture()
        capture2.script = [first, second]
        let queueController = makeController(capture2)
        await queueController.handle(.pressed(at: clock.nowNanos()))
        try? await Task.sleep(for: .milliseconds(300))
        await queueController.handle(.released(at: clock.nowNanos()))
        check("the first dictation is processing", queueController.phase == .processing)
        await queueController.handle(.pressed(at: clock.nowNanos()))
        check("the second press started recording while the first was processing",
              queueController.phase == .recording && capture2.starts == 2)
        check("the first had not been pasted yet when the second started", index(of: "plants") == nil)
        try? await Task.sleep(for: .milliseconds(300))
        await queueController.handle(.released(at: clock.nowNanos()))
        await queueController.waitForProcessing()
        // The paste chord is read by the text view on a later turn of the run loop.
        _ = await wait(timeout: 5) { index(of: "plants") != nil && index(of: "noon") != nil }
        let plants = index(of: "plants"), noon = index(of: "noon")
        report("text view: \(textView.string.replacingOccurrences(of: "\n", with: "\\n"))")
        check("both dictations were pasted", plants != nil && noon != nil)
        if let plants, let noon { check("they landed in the order they were spoken", plants < noon) }
        check("the controller is idle", queueController.phase == .idle)
        _ = await wait(timeout: 5) { !inserter.isRestorePending }

        // MARK: 3. Length limit

        report("-- 3. length limit")
        general.write("MT-SELFTEST-USER-CLIPBOARD", markers: [])
        let capture3 = SyntheticCapture()
        capture3.script = [third]
        let limited = makeController(
            capture3, limits: .init(warningAfter: 1.2, stopAfter: 3, partialFlushEvery: 0.4)
        )
        let pressedAt = Date()
        await limited.handle(.pressed(at: clock.nowNanos()))
        try? await Task.sleep(for: .milliseconds(900))
        let partials = (try? FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".partial.wav") } ?? []
        check("a recording in progress is saved as it goes", partials.count == 1 && ((try? partials[0].resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 44)
        let warned = await wait(timeout: 3) { presenter.state?.card.kind == .limitWarning }
        check("the warning card appeared", warned)
        check("it reads one minute left with the stop time", presenter.state?.card.header == "One minute left\nRecording stops at 3 seconds")
        // The same card with the real 20 minute limit for the screenshot; the run above used 3 seconds.
        presenter.present(.limitWarning(stopsAfter: DictationController.Limits.standard.stopAfter))
        try? await Task.sleep(for: .milliseconds(700))
        await saveShot(window: cards.panel.windowNumber, name: "card-one-minute-left.png")
        let stopped = await wait(timeout: 4) { limited.phase != .recording }
        let heldFor = Date().timeIntervalSince(pressedAt)
        report("recording stopped on its own after \(String(format: "%.1f", heldFor)) s")
        check("the recording stopped at the limit", stopped && heldFor > 2.5 && heldFor < 4.5 && capture3.stops == 1)
        await limited.waitForProcessing()
        _ = await wait(timeout: 5) { index(of: "quick reply") != nil || index(of: "thanks") != nil }
        check("it was processed and pasted like a release", index(of: "quick reply") != nil || index(of: "thanks") != nil)
        check("the warning card is gone", presenter.state?.card.kind != .limitWarning)
        let leftover = (try? FileManager.default.contentsOfDirectory(at: archive.directory, includingPropertiesForKeys: nil))?
            .filter { $0.lastPathComponent.hasSuffix(".partial.wav") } ?? []
        check("the in-progress copy was replaced by the archived WAV", leftover.isEmpty)
        _ = await wait(timeout: 5) { !inserter.isRestorePending }

        // MARK: 4. Microphone loss

        report("-- 4. microphone loss")
        general.write("MT-SELFTEST-USER-CLIPBOARD", markers: [])
        let capture4 = SyntheticCapture()
        capture4.script = [first, second]
        let lossController = makeController(capture4)
        let before = textView.string
        await lossController.handle(.pressed(at: clock.nowNanos()))
        try? await Task.sleep(for: .milliseconds(400))
        capture4.simulateDisconnect()
        let disconnected = await wait(timeout: 5) { presenter.state?.card.kind == .micDisconnected }
        check("the disconnect from a background thread raised the card", disconnected)
        let micCard = presenter.state?.card
        report("card header: \(micCard?.header.replacingOccurrences(of: "\n", with: " | ") ?? "none")")
        check("it reads Microphone disconnected, then the seconds on its own line",
              micCard?.header.hasPrefix("Microphone disconnected\n") == true && micCard?.header.hasSuffix(" seconds recorded") == true)
        check("it offers Insert and Discard", micCard?.actions == [.insert, .discard])
        check("nothing was pasted yet and the controller is idle", textView.string == before && lossController.phase == .idle)
        let lostID = latestAudioID()
        check("the audio was archived before the card showed",
              lostID != nil && (try? store.dictation(id: lostID ?? ""))?.status == .recorded)
        try? await Task.sleep(for: .milliseconds(700))
        await saveShot(window: cards.panel.windowNumber, name: "card-mic-disconnected.png")
        presenter.perform(.insert)
        let inserted = await wait(timeout: 30) { textView.string != before }
        check("Insert delivered the captured speech at the focus", inserted)
        await lossController.waitForProcessing()
        check("the row ended inserted", (try? store.dictation(id: lostID ?? ""))?.status == .inserted)
        _ = await wait(timeout: 5) { !inserter.isRestorePending }

        // Discard on a second loss.
        await lossController.handle(.pressed(at: clock.nowNanos()))
        try? await Task.sleep(for: .milliseconds(300))
        capture4.simulateDisconnect()
        _ = await wait(timeout: 5) { presenter.state?.card.kind == .micDisconnected }
        let discardedID = latestAudioID()
        let afterInsert = textView.string
        presenter.perform(.discard)
        let cancelled = await wait(timeout: 5) { (try? store.dictation(id: discardedID ?? ""))?.status == .cancelled }
        check("Discard ended the second row cancelled and pasted nothing", cancelled && textView.string == afterInsert)

        finish(window: window, general: general, snapshot: userClipboard, directory: directory)
    }

    private static func finish(window: NSWindow, general: SystemPasteboard, snapshot: PasteboardSnapshot, directory: URL) {
        general.restore(snapshot)
        report("restored the real clipboard")
        report(failures.isEmpty ? "PASS" : "FAIL: \(failures.joined(separator: "; "))")
        window.close()
        try? FileManager.default.removeItem(at: directory)
        NSApp.terminate(nil)
    }
}
