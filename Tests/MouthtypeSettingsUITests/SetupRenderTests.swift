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
        try render(model: model, actions: actions, name: "setup-pending", size: NSSize(width: 720, height: 730))
        #expect(!model.readiness.isReady)
        await host.load()
        diagnostics.microphoneStatus = .authorized
        diagnostics.accessibilityGranted = true
        diagnostics.hotkeyHealth = .listening
        model.captureReady = true
        #expect(model.readiness.isReady)
        try render(model: model, actions: actions, name: "setup-ready", size: NSSize(width: 720, height: 730))
        diagnostics.microphoneStatus = .denied
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(!model.readiness.isReady)
        try render(model: model, actions: actions, name: "setup-denied-minimum", size: NSSize(width: 620, height: 660))
        let failure = EngineHost(makeEngine: { _ in SetupRenderEngine(fails: true) })
        await failure.load()
        let failedModel = SetupModel(diagnostics: diagnostics, engine: failure, defaults: defaults)
        diagnostics.microphoneStatus = .authorized
        failedModel.captureError = "The selected microphone is unavailable. Connect an input device and try again."
        try render(model: failedModel, actions: actions, name: "setup-failed-minimum", size: NSSize(width: 620, height: 660))
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
