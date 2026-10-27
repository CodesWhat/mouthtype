import AppKit
import MouthtypeCore
import SwiftUI
import Testing

@testable import MouthtypeMac

/// Offscreen renders of the 0.6.0 UI pieces for an eyes pass. Runs only when `MOUTHTYPE_VISUAL_PASS_DIR` names a
/// directory, and writes one light and one dark PNG per piece there. Every model runs on a throwaway defaults suite, and
/// no window is ever shown. Open menus and a live sheet cannot draw offscreen, so those are not faked here.
private let visualPassDirectory = ProcessInfo.processInfo.environment["MOUTHTYPE_VISUAL_PASS_DIR"]

@MainActor @Suite(.serialized, .enabled(if: visualPassDirectory != nil)) struct VisualPassRenderTests {
    private func output() throws -> URL {
        let url = URL(fileURLWithPath: try #require(visualPassDirectory), isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output().appendingPathComponent(name + ".png"))
    }

    private func both(_ name: String, _ body: (Bool) throws -> NSBitmapImageRep) throws {
        for dark in [false, true] { try write(body(dark), "\(name)-\(dark ? "dark" : "light")") }
    }

    private func throwaway(_ body: (UserDefaults) throws -> Void) throws {
        let name = "VisualPass-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        try body(defaults)
    }

    private let modalSize = NSSize(width: SettingsModalView.size.width, height: SettingsModalView.size.height)

    private func modal(_ defaults: UserDefaults, page: SettingsModalPage, name: String, configure: (SettingsModel) -> Void = { _ in }) throws {
        let model = SettingsModel(defaults: defaults)
        model.setAdvancedOptions(true)
        model.modalPage = page
        configure(model)
        try both(name) { dark in
            try SettingsRender.render(SettingsModalView(model: model, actions: SettingsActions(cleaner: VisualCleaner())), dark: dark, size: modalSize)
        }
    }

    // MARK: a, b. General

    @Test func generalLanguageAndMouseButton() throws {
        try throwaway { defaults in
            try modal(defaults, page: .general, name: "a1-general-language-auto")
        }
        try throwaway { defaults in
            DictationLanguageSetting.set(.explicit(.german), in: defaults)
            try modal(defaults, page: .general, name: "a2-general-language-german")
        }
        try throwaway { defaults in
            MouseTriggerPreference.set(.back, in: defaults)
            try modal(defaults, page: .general, name: "b-general-mouse-button")
        }
    }

    // MARK: c. Dictionary

    @Test func dictionaryPageAndWisprImportSheet() throws {
        FontRegistry.registerBundledFonts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-visual-pass-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        for (heard, written) in [("priya", "Priya"), ("pre ya", "Priya"), ("mouth type", "Mouthtype"), ("tahoe", "Tahoe")] {
            try store.save(heard: heard, written: written)
        }
        let editor = SpellingEditor(store: store)
        let suggestions = SpellingSuggestionsModel(vocabulary: store, dismissedURL: dir.appendingPathComponent("dismissed.json"))
        let defaults = try #require(UserDefaults(suiteName: "VisualPassDictionary-\(UUID().uuidString)"))
        let model = SettingsModel(defaults: defaults, spellings: editor, spellingSuggestions: suggestions)
        model.page = .dictionary
        try both("c1-dictionary-page") { dark in
            try SettingsRender.render(model: model, actions: SettingsActions(cleaner: VisualCleaner()), dark: dark)
        }
        editor.previewImport(
            data: Data("Sean\nshawn,Sean\npriya,Priya\nDrydock\ndry doc,Drydock\nHyprland\n,Missing".utf8), fileName: "wispr-dictionary.csv", source: .wispr)
        try both("c2-dictionary-wispr-import") { dark in
            let host = NSHostingView(rootView: SpellingImportView(editor: editor).environment(\.colorScheme, dark ? .dark : .light))
            let window = NSWindow(contentRect: .zero, styleMask: [.titled], backing: .buffered, defer: false)
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            window.contentView = host
            host.setFrameSize(host.fittingSize)
            host.layoutSubtreeIfNeeded()
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            #expect(!window.isVisible)
            return bitmap
        }
    }

    // MARK: d. Silent-mic card

    private func cardBitmap(_ card: DeliveryCard, kind: PillSkinKind, dark: Bool) throws -> NSBitmapImageRep {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let backing: CGFloat = 2
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: kind.cardStyle, scale: .standard, embedded: false)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let size = view.render(CardViewState(card: card), typography: Typography.current())
        let canvas = CGSize(width: size.width + 24, height: size.height + 24)
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: true)
        window.appearance = view.appearance
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let face = try #require(
            NSBitmapImageRep(
                bitmapDataPlanes: nil, pixelsWide: Int(size.width * backing), pixelsHigh: Int(size.height * backing), bitsPerSample: 8,
                samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        face.size = size
        view.cacheDisplay(in: view.bounds, to: face)
        let context = try #require(
            CGContext(
                data: nil, width: Int(canvas.width * backing), height: Int(canvas.height * backing), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.scaleBy(x: backing, y: backing)
        let colors = (dark ? [NSColor(hex: 0x3B4A6B), NSColor(hex: 0x1D2436)] : [NSColor(hex: 0xEEF1F5), NSColor(hex: 0xC9D2E0)]).map(\.cgColor)
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: canvas.height), end: CGPoint(x: canvas.width, y: 0), options: [])
        context.interpolationQuality = .none
        if let image = face.cgImage { context.draw(image, in: CGRect(origin: CGPoint(x: 12, y: 12), size: size)) }
        let out = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
        #expect(!window.isVisible)
        return out
    }

    @Test func silentMicCards() throws {
        let longMic = "MacBook Pro Microphone (Built-in) and a very long aggregate device name"
        let cards: [(String, DeliveryCard)] = [
            ("noSignal", .silentMic(.noSignal, micName: "Desk Mic")),
            ("noSpeech", .silentMic(.noSpeech, micName: "Desk Mic")),
            ("noSignal-long-mic", .silentMic(.noSignal, micName: longMic)),
            ("noSpeech-long-mic", .silentMic(.noSpeech, micName: longMic)),
        ]
        for (skin, kind) in [("default", PillSkinKind.default), ("hifi", .hifi)] {
            for (label, card) in cards {
                try both("d-silent-\(skin)-\(label)") { try cardBitmap(card, kind: kind, dark: $0) }
            }
        }
    }

    // MARK: e. Setup last card

    private func setupBitmap(_ model: SetupModel, dark: Bool, size: NSSize) throws -> NSBitmapImageRep {
        let host = NSHostingView(
            rootView: SetupView(model: model, actions: SetupActions(), solid: true).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(!window.isVisible)
        return bitmap
    }

    private func samples(_ level: Float) -> CapturedAudio {
        CapturedAudio(
            samples: (0..<16_000).map { level * sin(Float($0) * 0.2) }, sampleRate: 16_000, deviceUID: nil, deviceName: "Desk Mic",
            deviceTransport: "usb", firstSampleMs: 0, firstNonzeroMs: nil, captureStartMs: 0, audioMs: 1_000)
    }

    /// A Setup model with every requirement passing. On the Models page until `finished`, which is Continue.
    private func readyModel(
        defaults: UserDefaults, take: SetupTestTake, listing: VisualListing? = nil, finished: Bool = true
    ) async throws -> SetupModel {
        let diagnostics = SettingsDiagnostics()
        diagnostics.microphoneStatus = .authorized
        diagnostics.accessibilityGranted = true
        diagnostics.hotkeyHealth = .listening
        let host = EngineHost(makeEngine: { _ in VisualEngine() })
        await host.load()
        let mic = MicrophonePreparation()
        _ = try await mic.prepare { true }
        let listing =
            listing
            ?? VisualListing(models: [
                CleanupModelStatus(level: .light, name: "S1-mini by Superwhisper", sizeMB: 1447, status: .done, selected: true),
                CleanupModelStatus(level: .medium, name: "Gemma 4 E4B", sizeMB: 5150, status: .available, selected: false),
            ])
        let model = SetupModel(diagnostics: diagnostics, engine: host, microphone: mic, cleanup: listing, testTake: take, defaults: defaults)
        #expect(model.readiness.step == .ready)
        if finished { model.finishModels() }
        #expect(model.step == (finished ? .ready : .models))
        return model
    }

    private func take(level: Float, text: String, sleep: @escaping @Sendable (Duration) async throws -> Void = { _ in await Task.yield() }) -> SetupTestTake {
        SetupTestTake(
            capture: VisualCapture(audio: samples(level)), engine: VisualTakeEngine(text: text), readLevel: { -20 },
            language: { .english }, sleep: sleep)
    }

    @Test func setupLastCard() async throws {
        let size = SetupWindow.contentSize
        func finish(_ take: SetupTestTake) async { for _ in 0..<2_000 where take.isBusy { await Task.yield() } }

        let name = "VisualPassSetup-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()

        // The final card's test take: idle, recording, spoken, silent.
        let idle = take(level: 0.3, text: "")
        let idleModel = try await readyModel(defaults: defaults, take: idle)
        try both("e2-setup-take-idle") { try setupBitmap(idleModel, dark: $0, size: size) }
        // The real window is fixed at `contentSize`; this taller frame shows whatever the last card holds below it.
        try both("e2b-setup-ready-tall") { try setupBitmap(idleModel, dark: $0, size: NSSize(width: size.width, height: 800)) }

        let ticks = TickGate(limit: 6)
        let recording = take(level: 0.3, text: "", sleep: { _ in try await ticks.tick() })
        let recordingModel = try await readyModel(defaults: defaults, take: recording)
        recording.start()
        for _ in 0..<2_000 where !ticks.reachedLimit { await Task.yield() }
        #expect(recording.state == .recording)
        try both("e3-setup-take-recording") { try setupBitmap(recordingModel, dark: $0, size: size) }
        await recording.cancel()

        let spoken = take(level: 0.3, text: "Send the mockups to Sean before Friday.")
        let spokenModel = try await readyModel(defaults: defaults, take: spoken)
        spoken.start()
        await finish(spoken)
        try both("e4-setup-take-spoken") { try setupBitmap(spokenModel, dark: $0, size: size) }

        let silent = take(level: 0, text: "")
        let silentModel = try await readyModel(defaults: defaults, take: silent)
        silent.start()
        await finish(silent)
        try both("e5-setup-take-silent") { try setupBitmap(silentModel, dark: $0, size: size) }
    }

    @Test func setupModelsPage() async throws {
        let size = SetupWindow.contentSize
        let name = "VisualPassModels-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        // Names reads the process-wide boost status; put it back after.
        defer { VocabularyBoostStatusCenter.set(.off) }

        // Mixed states: speech Ready, Fast downloading with progress, Thorough still a Download button, Names Ready.
        var fast = ModelDownloadProgress(hubCompletedUnits: 612_000_000, hubTotalUnits: 1_447_000_000)
        fast.secondsRemaining = 95
        let listing = VisualListing(models: [
            CleanupModelStatus(level: .light, name: "S1-mini by Superwhisper", sizeMB: 1447, status: .downloading(fast), selected: true),
            CleanupModelStatus(level: .medium, name: "Gemma 4 E4B", sizeMB: 5150, status: .available, selected: false),
        ])
        VocabularyBoostSetting.set(true, in: defaults)
        VocabularyBoostStatusCenter.set(.ready)
        let mixed = try await readyModel(defaults: defaults, take: take(level: 0.3, text: ""), listing: listing, finished: false)
        let states = mixed.modelEntries.map(\.state)
        guard case .ready = states[0], case .downloading = states[1], case .available = states[2], case .ready = states[3] else {
            Issue.record("unexpected model states \(states)")
            return
        }
        try both("e1-setup-models-mixed") { try setupBitmap(mixed, dark: $0, size: size) }
        // The window scrolls its card at `contentSize`, so the Names row sits below the fold. The list alone shows all four rows.
        let list = SetupModelsList(
            entries: mixed.modelEntries, retrySpeech: {}, downloadNames: {}, downloadCleanup: { _ in }, cancelCleanup: { _ in }
        ).padding(24)
        try both("e1b-setup-models-list-all-rows") { try SettingsRender.render(list, dark: $0, size: NSSize(width: 560, height: 430)) }
    }

    // MARK: f, g. Style page

    private func stylePage(_ model: SettingsModel, _ tab: StyleTab) -> some View {
        DesignPage(title: "Your words. Your way.", summary: "A tone for each kind of writing, and the apps that count as each kind.") {
            StylePage(model: model, actions: SettingsActions(cleaner: VisualCleaner()), initialTab: tab)
        }
    }

    @Test func cleanupInstructions() throws {
        try throwaway { defaults in
            let model = SettingsModel(defaults: defaults)
            let nearCap = String(
                "Keep it plain and direct. Short sentences, no filler. Use bullet points when I list things, and put action items last. Never sign off with a greeting. Spell my product names exactly as I say them. "
                    .repeated(to: CleanupInstructions.maxLength - 12))
            model.setInstructions(nearCap)
            model.setAppStyle(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .formal)
            model.setAppInstructions(
                bundleIDs: ["com.tinyspeck.slackmacgap"], appName: "Slack", instructions: "Short and friendly. No bullet points in channels.")
            model.addContextSite(.work, domain: "linear.app")
            model.setWebsiteInstructions(domain: "linear.app", instructions: "Put action items in a bullet list.")
            let size = NSSize(width: 900, height: 1500)
            try both("f1-cleanup-tab-global-instructions") { try SettingsRender.render(stylePage(model, .cleanup), dark: $0, size: size) }
            try both("f2-work-tab-rule-with-instructions") { try SettingsRender.render(stylePage(model, .context(.work)), dark: $0, size: size) }
        }
        // The per-app box opens from a private @State on the row, so it renders as the editor itself with that rule's text.
        for (label, saved) in [("short", "Short and friendly. No bullet points in channels."), ("near-cap", String("x".repeated(to: CleanupInstructions.maxLength - 3)))] {
            let content = DesignCard {
                StyleInstructionsEditor(
                    saved: saved, placeholder: StyleContextID.work.instructionsExample, label: "Instructions for Slack", identifier: "visual-pass-\(label)"
                ) { _ in }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }.padding(20)
            try both("f3-per-app-instructions-editor-\(label)") { try SettingsRender.render(content, dark: $0, size: NSSize(width: 720, height: 220)) }
        }
    }

    @Test func excitedToneCard() throws {
        try throwaway { defaults in
            let model = SettingsModel(defaults: defaults)
            model.setContextTone(.personal, .excited)
            model.setAppStyle(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", tone: .excited)
            try both("g-style-excited-tone") {
                try SettingsRender.render(stylePage(model, .context(.personal)), dark: $0, size: NSSize(width: 900, height: 1500))
            }
        }
    }

    // MARK: i. Website favicons

    private func fakeFavicon(_ colour: NSColor, letter: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 64, height: 64), flipped: false) { rect in
            colour.setFill()
            NSBezierPath(roundedRect: rect, xRadius: 14, yRadius: 14).fill()
            let text = NSAttributedString(
                string: letter, attributes: [.font: NSFont.boldSystemFont(ofSize: 40), .foregroundColor: NSColor.white])
            let box = text.size()
            text.draw(at: NSPoint(x: rect.midX - box.width / 2, y: rect.midY - box.height / 2))
            return true
        }
        let tiff = try #require(image.tiffRepresentation)
        return try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
    }

    @Test func websiteRulesWithFavicons() async throws {
        // Fake icons for hosts that cannot exist, in a temp store whose fetch always fails, so one more host keeps the globe.
        let icons = [
            ("docs.visual-pass.example", NSColor.systemIndigo, "D"), ("mail.visual-pass.example", NSColor.systemOrange, "M"),
            ("tracker.visual-pass.example", NSColor.systemTeal, "T"),
        ]
        let missing = "plain.visual-pass.example"
        let favicons = SettingsRender.fakeFavicons(icons: Dictionary(uniqueKeysWithValues: try icons.map { ($0.0, try fakeFavicon($0.1, letter: $0.2)) }))

        try throwaway { defaults in
            let model = SettingsModel(defaults: defaults)
            for host in icons.map(\.0) + [missing] { model.addContextSite(.work, domain: host) }
            model.setWebsiteInstructions(domain: icons[0].0, instructions: "Put action items in a bullet list.")
            let size = NSSize(width: 900, height: 900)
            for dark in [false, true] {
                let (view, window) = SettingsRender.host(stylePage(model, .context(.work)), dark: dark, size: size, favicons: favicons)
                // The icon loads in a task after the first layout; let it land before drawing.
                for _ in 0..<20 {
                    RunLoop.current.run(until: Date().addingTimeInterval(0.05))
                    view.layoutSubtreeIfNeeded()
                }
                let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
                view.cacheDisplay(in: view.bounds, to: bitmap)
                #expect(!window.isVisible)
                try write(bitmap, "i-website-rules-favicons-\(dark ? "dark" : "light")")
            }
        }
    }

    // MARK: j. Start from… presets

    @Test func startFromPresetButton() throws {
        let chosen = try #require(CleanupInstructionPresets.all.first)
        for (label, saved) in [("empty", nil), ("preset-text", StyleInstructionsEditor.draft(startingFrom: chosen))] as [(String, String?)] {
            let content = DesignCard {
                StyleInstructionsEditor(
                    saved: saved, placeholder: StyleContextID.work.instructionsExample, label: "Instructions", identifier: "visual-pass-preset-\(label)"
                ) { _ in }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }.padding(20)
            try both("j-start-from-presets-\(label)") { try SettingsRender.render(content, dark: $0, size: NSSize(width: 720, height: 220)) }
        }
    }

    // MARK: h. Advanced > Recognition

    @Test func advancedRecognition() throws {
        try throwaway { defaults in
            VocabularyBoostSetting.set(true, in: defaults)
            #expect(ContextNamesSetting.isEnabled(defaults))
            try modal(defaults, page: .advanced, name: "h-advanced-recognition")
        }
    }

    // MARK: k. Advanced > Press Return after inserting

    @Test func pressReturnAfterInserting() throws {
        try throwaway { defaults in
            SendAfterInsertSettings(defaults: defaults).add("com.apple.MobileSMS")
            SendAfterInsertSettings(defaults: defaults).add("com.tinyspeck.slackmacgap")
            let model = SettingsModel(defaults: defaults)
            let section = ScrollView { SendAfterInsertSection(model: model).padding(20) }
            try both("k-press-return-after-inserting") { try SettingsRender.render(section, dark: $0, size: NSSize(width: 720, height: 300)) }
        }
        try throwaway { defaults in
            let section = ScrollView { SendAfterInsertSection(model: SettingsModel(defaults: defaults)).padding(20) }
            try both("k-press-return-after-inserting-empty") { try SettingsRender.render(section, dark: $0, size: NSSize(width: 720, height: 220)) }
        }
    }
}

private extension String {
    /// This text repeated and cut to exactly `count` characters.
    func repeated(to count: Int) -> String {
        guard !isEmpty, count > 0 else { return "" }
        return String(String(repeating: self, count: count / self.count + 1).prefix(count))
    }
}

@MainActor private final class VisualCleaner: CleanupModelManaging {
    var state = CleanerState.ready(loadSeconds: 1)
    let modelName = "Fast cleanup"
    let downloadSizeMB = 600
    func start() {}
    func levelChanged() {}
    func startDownload() {}
    func cancelDownload() {}
    nonisolated func recordingStarted() {}
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { nil }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { fatalError("Rendering does not run cleanup") }
}

private struct VisualEngine: Transcriber {
    let id = "parakeet-tdt-v3"
    let displayName = "Render only"
    func prepare() async throws {}
    func transcribe(samples: [Float]) async throws -> Transcription { Transcription(text: "", processingSeconds: 0, engineID: id) }
}

@MainActor private final class VisualListing: CleanupModelListing {
    var models: [CleanupModelStatus]
    init(models: [CleanupModelStatus]) { self.models = models }
    func cleanupModels() -> [CleanupModelStatus] { models }
    func downloadCleanupModel(_ level: CleanupLevel) {}
    func cancelCleanupDownload(_ level: CleanupLevel) {}
}

@MainActor private final class VisualCapture: DictationCapturing {
    var isPrepared = true
    let audio: CapturedAudio
    init(audio: CapturedAudio) { self.audio = audio }
    func start(keyDownAtNanos: UInt64) async throws {}
    func stop() async throws -> CapturedAudio { audio }
    func cancel() async {}
}

@MainActor private final class VisualTakeEngine: DictationEngine {
    var readiness: EngineReadiness { .ready }
    let text: String
    init(text: String) { self.text = text }
    func transcribe(samples: [Float]) async throws -> Transcription { Transcription(text: text, processingSeconds: 0, engineID: "fake") }
    func setVocabularyBias(_ bias: VocabularyBias?) async {}
}

/// Lets a test take tick a few times, then holds it mid-recording until the take is cancelled.
private final class TickGate: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let limit: Int
    init(limit: Int) { self.limit = limit }
    var reachedLimit: Bool { lock.withLock { count > limit } }
    func tick() async throws {
        let hold = lock.withLock { () -> Bool in
            count += 1
            return count > limit
        }
        if hold { try await Task.sleep(for: .seconds(3600)) } else { await Task.yield() }
    }
}
