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
        let actions = SetupActions(refresh: count, microphone: count, accessibility: count, retrySpeech: count, inputSettings: count, done: count)
        let controller = SetupWindow(model: model, actions: actions)
        #expect(controller.window?.title == "Set Up Mouthtype")
        try render(model: model, actions: actions, name: "setup-pending", size: NSSize(width: 650, height: 590))
        #expect(model.readiness.step == .microphone)
        diagnostics.microphoneStatus = .denied
        try render(model: model, actions: actions, name: "setup-denied-minimum", size: NSSize(width: 560, height: 540))
        diagnostics.microphoneStatus = .authorized
        model.capturePreparing = true
        try render(model: model, actions: actions, name: "setup-microphone-preparing", size: NSSize(width: 650, height: 590))
        model.capturePreparing = false
        model.captureError = "The selected microphone is unavailable. Connect an input device and try again."
        try render(model: model, actions: actions, name: "setup-microphone-failed-minimum", size: NSSize(width: 560, height: 540))
        model.captureReady = true
        #expect(model.readiness.step == .accessibility)
        try render(model: model, actions: actions, name: "setup-accessibility", size: NSSize(width: 650, height: 590))
        diagnostics.accessibilityGranted = true
        #expect(model.readiness.step == .speech)
        try render(model: model, actions: actions, name: "setup-model-loading", size: NSSize(width: 650, height: 590))
        await host.load()
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(model.readiness.step == .shortcut)
        try render(model: model, actions: actions, name: "setup-input-minimum", size: NSSize(width: 560, height: 540))
        diagnostics.hotkeyHealth = .listening
        #expect(model.readiness.isReady)
        try render(model: model, actions: actions, name: "setup-ready", size: NSSize(width: 650, height: 590))
        let failure = EngineHost(makeEngine: { _ in SetupRenderEngine(fails: true) })
        await failure.load()
        let failedModel = SetupModel(diagnostics: diagnostics, engine: failure, defaults: defaults)
        failedModel.captureReady = true
        #expect(failedModel.readiness.step == .speech)
        try render(model: failedModel, actions: actions, name: "setup-failed-minimum", size: NSSize(width: 560, height: 540))
        #expect(!failedModel.readiness.isReady)
        #expect(actionsInvoked == 0)
        #expect(controller.window?.isVisible == false)
        #expect(defaults.object(forKey: SetupLaunchPolicy.presentedKey) == nil)
    }

    private func render(model: SetupModel, actions: SetupActions, name: String, size: NSSize) throws {
        let controller = SetupWindow(model: model, actions: actions)
        controller.window?.setContentSize(size)
        let view = try #require(controller.window?.contentView)
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
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
