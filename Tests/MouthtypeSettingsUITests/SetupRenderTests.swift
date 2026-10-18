import AppKit
import AVFoundation
import MouthtypeCore
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SetupRenderTests {
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
        try render(model: model, actions: actions, name: "setup-pending", size: NSSize(width: 560, height: 440))
        try render(model: model, actions: actions, name: "setup-pending-light", size: NSSize(width: 560, height: 440), appearance: .aqua)
        #expect(model.readiness.step == .microphone)
        diagnostics.microphoneStatus = .denied
        try render(model: model, actions: actions, name: "setup-denied-minimum", size: NSSize(width: 560, height: 440))
        diagnostics.microphoneStatus = .authorized
        var finishPreparation: CheckedContinuation<Bool, any Error>?
        var preparation: Task<Bool, any Error>!
        await withCheckedContinuation { started in
            preparation = Task { try await model.microphone.prepare {
                try await withCheckedThrowingContinuation {
                    finishPreparation = $0
                    started.resume()
                }
            } }
        }
        try render(model: model, actions: actions, name: "setup-microphone-preparing", size: NSSize(width: 560, height: 440))
        finishPreparation?.resume(throwing: CaptureError.selectedMicrophoneUnavailable)
        _ = try? await preparation.value
        try render(model: model, actions: actions, name: "setup-microphone-failed-minimum", size: NSSize(width: 560, height: 440))
        _ = try await model.microphone.prepare { true }
        #expect(model.readiness.step == .accessibility)
        try render(model: model, actions: actions, name: "setup-accessibility", size: NSSize(width: 560, height: 440))
        diagnostics.accessibilityGranted = true
        #expect(model.readiness.step == .speech)
        try render(model: model, actions: actions, name: "setup-model-loading", size: NSSize(width: 560, height: 440))
        await host.load()
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(model.readiness.step == .shortcut)
        try render(model: model, actions: actions, name: "setup-input-minimum", size: NSSize(width: 560, height: 440))
        diagnostics.hotkeyHealth = .listening
        #expect(model.readiness.isReady)
        try render(model: model, actions: actions, name: "setup-ready", size: NSSize(width: 560, height: 440))
        try render(model: model, actions: actions, name: "setup-ready-light-minimum", size: NSSize(width: 560, height: 440), appearance: .aqua)
        let failure = EngineHost(makeEngine: { _ in SetupRenderEngine(fails: true) })
        await failure.load()
        let failedModel = SetupModel(diagnostics: diagnostics, engine: failure, defaults: defaults)
        _ = try await failedModel.microphone.prepare { true }
        #expect(failedModel.readiness.step == .speech)
        try render(model: failedModel, actions: actions, name: "setup-failed-minimum", size: NSSize(width: 560, height: 440))
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
        let glass = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: false)
        #expect(glass.window?.contentView is NSGlassEffectView)
        #expect(glass.window?.styleMask.contains(.fullSizeContentView) == true)
        #expect(glass.window?.titlebarAppearsTransparent == true)
        #expect(glass.window?.contentRect(forFrameRect: glass.window?.frame ?? .zero).size == SetupWindow.contentSize)
        let solid = SetupWindow(model: model, actions: SetupActions(), reduceTransparency: true)
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
        try both("5-ready")
    }

    /// Renders the SwiftUI sheet on its solid fallback background. The glass layer doesn't draw into an
    /// offscreen bitmap, so the material itself is only checked structurally (see `windowUsesGlass`).
    private func render(model: SetupModel, actions: SetupActions, name: String, size: NSSize, appearance: NSAppearance.Name? = nil) throws {
        let controller = SetupWindow(model: model, actions: actions)
        let dark = appearance == .darkAqua
        let host = NSHostingView(rootView: SetupView(model: model, actions: actions, solid: true)
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
