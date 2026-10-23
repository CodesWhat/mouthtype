import AppKit
import AVFoundation
import MouthtypeCore
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SetupRenderTests {
    @Test func sidebarSecondaryInkHoldsContrastOverBothGradientEnds() throws {
        func rgb(_ colour: NSColor) -> [Double] {
            let c = colour.usingColorSpace(.sRGB) ?? colour
            return [c.redComponent, c.greenComponent, c.blueComponent].map { Double($0) }
        }
        func luminance(_ channels: [Double]) -> Double {
            let lin = channels.map { $0 <= 0.03928 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return 0.2126 * lin[0] + 0.7152 * lin[1] + 0.0722 * lin[2]
        }
        for dark in [false, true] {
            let appearance = try #require(NSAppearance(named: dark ? .darkAqua : .aqua))
            var ink: [Double] = [], base: [Double] = [], ends: [(rgb: [Double], alpha: Double)] = []
            appearance.performAsCurrentDrawingAppearance {
                ink = rgb(DesignPalette.NS.sideInk)
                base = rgb(DesignPalette.NS.sideBase)
                ends = [DesignPalette.NS.sideTop, DesignPalette.NS.sideBottom].map {
                    let c = $0.usingColorSpace(.sRGB) ?? $0
                    return (rgb($0), Double(c.alphaComponent))
                }
            }
            for end in ends {
                // Reduce Transparency lays the wash over the opaque base.
                let ground = zip(end.rgb, base).map { end.alpha * $0 + (1 - end.alpha) * $1 }
                let (a, b) = (luminance(ink), luminance(ground))
                #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
            }
        }
    }

    @Test func setupRendersPendingReadyAndFailureWithoutOpeningOrRequestingAccess() async throws {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let diagnostics = SettingsDiagnostics()
        let host = EngineHost(makeEngine: { _ in SetupRenderEngine() })
        let model = SetupModel(diagnostics: diagnostics, engine: host, defaults: defaults)
        var actionsInvoked = 0
        let count = { actionsInvoked += 1 }
        let actions = SetupActions(refresh: count, poll: count, microphone: count, accessibility: count, retrySpeech: count, inputSettings: count, done: count)
        let controller = SetupWindow(model: model, actions: actions)
        #expect(controller.window?.title == "Set Up Mouthtype")
        try render(model: model, actions: actions, name: "setup-pending", size: SetupWindow.contentSize)
        try render(model: model, actions: actions, name: "setup-pending-light", size: SetupWindow.contentSize, appearance: .aqua)
        #expect(model.readiness.step == .microphone)
        diagnostics.microphoneStatus = .denied
        try render(model: model, actions: actions, name: "setup-denied-minimum", size: SetupWindow.contentSize)
        diagnostics.microphoneStatus = .authorized
        var finishPreparation: CheckedContinuation<Bool, any Error>?
        var preparation: Task<Bool, any Error>!
        await withCheckedContinuation { started in
            preparation = Task {
                try await model.microphone.prepare {
                    try await withCheckedThrowingContinuation {
                        finishPreparation = $0
                        started.resume()
                    }
                }
            }
        }
        try render(model: model, actions: actions, name: "setup-microphone-preparing", size: SetupWindow.contentSize)
        finishPreparation?.resume(throwing: CaptureError.selectedMicrophoneUnavailable)
        _ = try? await preparation.value
        try render(model: model, actions: actions, name: "setup-microphone-failed-minimum", size: SetupWindow.contentSize)
        _ = try await model.microphone.prepare { true }
        #expect(model.readiness.step == .accessibility)
        try render(model: model, actions: actions, name: "setup-accessibility", size: SetupWindow.contentSize)
        diagnostics.accessibilityGranted = true
        #expect(model.readiness.step == .speech)
        try render(model: model, actions: actions, name: "setup-model-loading", size: SetupWindow.contentSize)
        await host.load()
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(model.readiness.step == .shortcut)
        try render(model: model, actions: actions, name: "setup-input-minimum", size: SetupWindow.contentSize)
        diagnostics.hotkeyHealth = .listening
        #expect(model.readiness.isReady)
        #expect(model.step == .models)
        try render(model: model, actions: actions, name: "setup-models", size: SetupWindow.contentSize)
        model.finishModels()
        try render(model: model, actions: actions, name: "setup-ready", size: SetupWindow.contentSize)
        try render(model: model, actions: actions, name: "setup-ready-light-minimum", size: SetupWindow.contentSize, appearance: .aqua)
        let failure = EngineHost(makeEngine: { _ in SetupRenderEngine(fails: true) })
        await failure.load()
        let failedModel = SetupModel(diagnostics: diagnostics, engine: failure, defaults: defaults)
        _ = try await failedModel.microphone.prepare { true }
        #expect(failedModel.readiness.step == .speech)
        try render(model: failedModel, actions: actions, name: "setup-failed-minimum", size: SetupWindow.contentSize)
        #expect(!failedModel.readiness.isReady)
        #expect(actionsInvoked == 0)
        #expect(controller.window?.isVisible == false)
        #expect(defaults.object(forKey: SetupLaunchPolicy.presentedKey) == nil)
    }

    @Test func windowUsesGlassWithTrafficLightsInsideAndFixedContentSize() {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: EngineHost(makeEngine: { _ in SetupRenderEngine() }), defaults: defaults)
        let glass = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: { false })
        #expect(glass.window?.contentView is NSGlassEffectView)
        #expect(glass.window?.styleMask.contains(.fullSizeContentView) == true)
        #expect(glass.window?.titlebarAppearsTransparent == true)
        #expect(glass.window?.contentRect(forFrameRect: glass.window?.frame ?? .zero).size == SetupWindow.contentSize)
        let solid = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: { true })
        #expect(!(solid.window?.contentView is NSGlassEffectView))
    }

    @Test func pollRunsOnlyWhileTheWindowIsKey() async throws {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let host = EngineHost(makeEngine: { _ in SetupRenderEngine() })
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: host, defaults: defaults)
        var polls = 0
        var refreshes = 0
        let actions = SetupActions(refresh: { refreshes += 1 }, poll: { polls += 1 })
        let controller = SetupWindow(model: model, actions: actions, pollInterval: 0.02)
        let key = Notification(name: NSWindow.didBecomeKeyNotification)
        #expect(!controller.isPolling)
        controller.windowDidBecomeKey(key)
        #expect(controller.isPolling)
        #expect(refreshes == 1)
        controller.windowDidBecomeKey(key)
        #expect(controller.isPolling)
        try await Task.sleep(for: .milliseconds(200))
        #expect(polls > 0)
        controller.windowDidResignKey(Notification(name: NSWindow.didResignKeyNotification))
        #expect(!controller.isPolling)
        let stopped = polls
        try await Task.sleep(for: .milliseconds(100))
        #expect(polls == stopped)
        controller.windowDidBecomeKey(key)
        #expect(controller.isPolling)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!controller.isPolling)
    }

    @Test func realWindowFooterClearsTheSafeAreaWithBottomMargin() throws {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: EngineHost(makeEngine: { _ in SetupRenderEngine() }), defaults: defaults)
        for dark in [false, true] {
            let controller = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: { true })
            let window = try #require(controller.window)
            #expect(window.styleMask.contains(.fullSizeContentView))
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let content = try #require(window.contentView)
            content.layoutSubtreeIfNeeded()
            let hosting = try #require(content as? NSHostingView<SetupView>)
            let bounds = hosting.bounds
            #expect(bounds.size == SetupWindow.contentSize)
            let bitmap = try #require(hosting.bitmapImageRepForCachingDisplay(in: bounds))
            hosting.cacheDisplay(in: bounds, to: bitmap)
            // The footer is the lowest ink on the sheet. Measure the clear band under it from the real render.
            let scale = CGFloat(bitmap.pixelsHigh) / bounds.height
            let background = try #require(bitmap.colorAt(x: 1, y: bitmap.pixelsHigh - 1))
            func isInk(_ x: Int, _ y: Int) -> Bool {
                guard let c = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), let b = background.usingColorSpace(.sRGB) else { return false }
                return abs(c.redComponent - b.redComponent) + abs(c.greenComponent - b.greenComponent) + abs(c.blueComponent - b.blueComponent) > 0.15
            }
            var lowestInkRow = -1
            scan: for y in stride(from: bitmap.pixelsHigh - 1, through: 0, by: -1) {
                for x in stride(from: 0, to: bitmap.pixelsWide, by: 1) where isInk(x, y) { lowestInkRow = y; break scan }
            }
            let bottomMargin = CGFloat(bitmap.pixelsHigh - 1 - lowestInkRow) / scale
            print("setup real-window dark=\(dark) footer bottom margin = \(bottomMargin) pt, lowest ink row \(lowestInkRow) of \(bitmap.pixelsHigh)")
            #expect(lowestInkRow >= 0)
            #expect(bottomMargin >= 12, "footer ink within \(bottomMargin) pt of the bottom edge")
            // Footer ink must also exist in the bottom band on both the leading and trailing sides (Done/Set up later and the step names).
            let bandTop = bitmap.pixelsHigh - Int(48 * scale)
            func hasInk(xRange: Range<Int>) -> Bool {
                for y in bandTop..<bitmap.pixelsHigh { for x in xRange where isInk(x, y) { return true } }
                return false
            }
            #expect(hasInk(xRange: 0..<bitmap.pixelsWide / 3), "footer button missing from the bottom band")
            #expect(hasInk(xRange: bitmap.pixelsWide * 2 / 3..<bitmap.pixelsWide), "footer step names missing from the bottom band")
            let output = URL(fileURLWithPath: "/tmp/mt-visual/setup", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent("real-window-\(dark ? "dark" : "light").png"))
        }
    }

    @Test func reduceTransparencySwapsGlassAndSolidLive() {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SetupModel(diagnostics: SettingsDiagnostics(), engine: EngineHost(makeEngine: { _ in SetupRenderEngine() }), defaults: defaults)
        let center = NotificationCenter()
        var reduced = false
        let controller = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: { reduced }, notifications: center)
        #expect(controller.window?.contentView is NSGlassEffectView)
        #expect(!controller.isObservingTransparency)
        controller.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification))
        #expect(controller.isObservingTransparency)
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(!(controller.window?.contentView is NSGlassEffectView))
        reduced = false
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(controller.window?.contentView is NSGlassEffectView)
        controller.windowWillClose(Notification(name: NSWindow.willCloseNotification))
        #expect(!controller.isObservingTransparency)
        reduced = true
        center.post(name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil)
        #expect(controller.window?.contentView is NSGlassEffectView)
    }

    @Test func everyStepRendersInLightAndDark() async throws {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let diagnostics = SettingsDiagnostics()
        let host = EngineHost(makeEngine: { _ in SetupRenderEngine() })
        let model = SetupModel(diagnostics: diagnostics, engine: host, defaults: defaults)
        let actions = SetupActions()
        let size = SetupWindow.contentSize
        func both(_ label: String) throws {
            try render(model: model, actions: actions, name: "setup-\(label)-light", size: size, appearance: .aqua)
            try render(model: model, actions: actions, name: "setup-\(label)-dark", size: size, appearance: .darkAqua)
        }
        #expect(model.readiness.step == .microphone)
        try both("1-microphone")
        diagnostics.microphoneStatus = .authorized
        _ = try await model.microphone.prepare { true }
        #expect(model.readiness.step == .accessibility)
        try both("2-accessibility")
        diagnostics.accessibilityGranted = true
        #expect(model.readiness.step == .speech)
        try both("3-speech")
        await host.load()
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(model.readiness.step == .shortcut)
        try both("4-shortcut")
        diagnostics.hotkeyHealth = .listening
        #expect(model.readiness.step == .ready)
        #expect(model.step == .models)
        try both("5-models")
        model.finishModels()
        #expect(model.step == .ready)
        try both("6-ready")
    }

    @Test func speechStepDrawsADeterminateBarAndModelsStepListsBothCleanupModels() async throws {
        let name = "SetupRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let diagnostics = SettingsDiagnostics()
        diagnostics.microphoneStatus = .authorized
        diagnostics.accessibilityGranted = true
        diagnostics.hotkeyHealth = .listening
        let size = SetupWindow.contentSize
        let actions = SetupActions()
        let micModel = SetupModel(diagnostics: diagnostics, engine: EngineHost(makeEngine: { _ in SetupRenderEngine() }), defaults: defaults)
        _ = try await micModel.microphone.prepare { true }

        // Speech step, mid-download: 213 of 483 MB at 44% with a time estimate, and an earlier 20% for comparison.
        let gate = ProgressGate()
        func speechModel(fraction: Double) async -> SetupModel {
            var clock = 0.0
            let engine = ProgressRenderEngine(steps: [fraction - 0.01, fraction].map { .progress(ModelDownloadProgress(fraction: $0, knownTotalBytes: 483_000_000)) }, gate: gate)
            let host = EngineHost(
                makeEngine: { _ in engine },
                uptime: {
                    defer { clock += 3 }; return clock
                })
            host.start()
            for _ in 0..<300 where host.downloadProgress?.fraction != fraction { try? await Task.sleep(for: .milliseconds(10)) }
            return SetupModel(diagnostics: diagnostics, engine: host, microphone: micModel.microphone, defaults: defaults)
        }
        let early = await speechModel(fraction: 0.2)
        let mid = await speechModel(fraction: 0.44)
        #expect(early.readiness.step == .speech && mid.readiness.step == .speech)
        guard case let .downloading(shown) = mid.engine.downloadStatus else { Issue.record("not downloading"); return }
        #expect(ModelDownloadFormat.caption(shown).hasPrefix("213 of 483 MB"))
        let earlyBitmap = try bitmap(model: early, actions: actions, size: size, appearance: .aqua)
        let midBitmap = try bitmap(model: mid, actions: actions, size: size, appearance: .aqua)
        #expect(earlyBitmap.representation(using: .png, properties: [:]) != midBitmap.representation(using: .png, properties: [:]), "the bar fill moves with progress")
        try save(midBitmap, name: "setup-progress-speech-light")
        try save(try bitmap(model: mid, actions: actions, size: size, appearance: .darkAqua), name: "setup-progress-speech-dark")

        // Models step: Fast downloading, Thorough available.
        var fast = ModelDownloadProgress(hubCompletedUnits: 612_000_000, hubTotalUnits: 1_447_000_000)
        fast.secondsRemaining = 95
        let listing = FakeCleanupListing(models: [
            CleanupModelStatus(level: .light, name: "S1-mini by Superwhisper", sizeMB: 1447, status: .downloading(fast), selected: true),
            CleanupModelStatus(level: .medium, name: "Gemma 4 E4B", sizeMB: 5150, status: .available, selected: false),
        ])
        let readyHost = EngineHost(makeEngine: { _ in SetupRenderEngine() })
        await readyHost.load()
        let ready = SetupModel(diagnostics: diagnostics, engine: readyHost, microphone: micModel.microphone, cleanup: listing, defaults: defaults)
        #expect(ready.step == .models)
        #expect(ready.cleanupModels.count == 2)
        #expect(ready.modelEntries.count == 4)
        try save(try bitmap(model: ready, actions: actions, size: size, appearance: .aqua), name: "setup-progress-ready-light")
        try save(try bitmap(model: ready, actions: actions, size: size, appearance: .darkAqua), name: "setup-progress-ready-dark")
        listing.models[0].status = .done
        listing.models[1].status = .failed(message: "The network connection was lost.")
        try save(try bitmap(model: ready, actions: actions, size: size, appearance: .aqua), name: "setup-progress-ready-done-failed-light")
        ready.downloadCleanupModel(.medium)
        #expect(listing.requested == [.medium])
        ready.cancelCleanupDownload(.light)
        #expect(listing.cancelled == [.light])
        await gate.release()
    }

    private func bitmap(model: SetupModel, actions: SetupActions, size: NSSize, appearance: NSAppearance.Name) throws -> NSBitmapImageRep {
        let dark = appearance == .darkAqua
        let host = NSHostingView(
            rootView: SetupView(model: model, actions: actions, solid: true)
                .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        return bitmap
    }

    private func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] else { return }
        let output = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: output.appendingPathComponent(name + ".png"))
    }

    /// Renders the SwiftUI sheet on its solid fallback background. The glass layer doesn't draw into an
    /// offscreen bitmap, so the material itself is only checked structurally (see `windowUsesGlass`).
    private func render(model: SetupModel, actions: SetupActions, name: String, size: NSSize, appearance: NSAppearance.Name? = nil) throws {
        let controller = SetupWindow(model: model, actions: actions)
        let dark = appearance == .darkAqua
        let host = NSHostingView(
            rootView: SetupView(model: model, actions: actions, solid: true)
                .environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        #expect(controller.window?.isVisible == false)
        #expect(bitmap.pixelsWide >= Int(size.width) && bitmap.pixelsHigh >= Int(size.height))
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let output = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: output.appendingPathComponent(name + ".png"))
        }
    }
}

private struct SetupRenderEngine: Transcriber {
    let id = "parakeet-tdt-v3"
    let displayName = "Render only"
    var fails = false
    func prepare() async throws { if fails { throw CocoaError(.fileReadNoSuchFile) } }
    func transcribe(samples: [Float]) async throws -> Transcription { Transcription(text: "", processingSeconds: 0, engineID: id) }
}

private actor ProgressGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Reports scripted download progress, then holds the model "downloading" until the test lets go.
private actor ProgressRenderEngine: PreparationReporting {
    nonisolated let id = "parakeet-tdt-v3"
    nonisolated let displayName = "Render only"
    let steps: [EnginePreparation]
    let gate: ProgressGate
    init(steps: [EnginePreparation], gate: ProgressGate) {
        self.steps = steps
        self.gate = gate
    }
    func prepare() async throws {}
    func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws {
        for step in steps { await report(step) }
        await gate.wait()
    }
    func transcribe(samples: [Float]) async throws -> Transcription { Transcription(text: "", processingSeconds: 0, engineID: id) }
}

@MainActor private final class FakeCleanupListing: CleanupModelListing {
    var models: [CleanupModelStatus]
    private(set) var requested: [CleanupLevel] = []
    init(models: [CleanupModelStatus]) { self.models = models }
    func cleanupModels() -> [CleanupModelStatus] { models }
    func downloadCleanupModel(_ level: CleanupLevel) { requested.append(level) }
    func cancelCleanupDownload(_ level: CleanupLevel) { cancelled.append(level) }
    private(set) var cancelled: [CleanupLevel] = []
}
