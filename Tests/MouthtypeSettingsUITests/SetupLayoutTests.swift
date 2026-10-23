import AppKit
import AVFoundation
import MouthtypeCore
import SwiftUI
import Testing

@testable import MouthtypeMac

/// Setup is a fixed-size window, so every step's card, including its primary button, has to fit without the scroll view scrolling.
@MainActor @Suite(.serialized) struct SetupLayoutTests {
    private func descendants(of view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants(of: $0) } }

    private func defaults() throws -> (UserDefaults, () -> Void) {
        let name = "SetupLayout-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        FontRegistry.registerBundledFonts()
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    /// Hosts the step at the window's content size and returns how far the card overflows the visible scroll area (0 or less fits).
    private func overflow(_ model: SetupModel, dark: Bool) throws -> CGFloat {
        let size = SetupWindow.contentSize
        let host = NSHostingView(
            rootView: SetupView(model: model, actions: SetupActions(), solid: true).environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = host
        host.setFrameSize(size)
        host.layoutSubtreeIfNeeded()
        let scroll = try #require(descendants(of: host).compactMap { $0 as? NSScrollView }.first)
        let document = try #require(scroll.documentView)
        return document.frame.height - scroll.contentView.bounds.height
    }

    private func expectFits(_ model: SetupModel, _ label: String) throws {
        for dark in [false, true] {
            let over = try overflow(model, dark: dark)
            #expect(over <= 1, "\(label) (dark \(dark)) overflows the Setup window by \(over) pt")
        }
    }

    @Test func windowIsTallEnoughForEveryStepYetShortEnoughForALaptop() {
        #expect(SetupWindow.contentSize.width == 560)
        #expect(SetupWindow.contentSize.height < 600)
    }

    @Test func everyStepFitsWithItsPrimaryButton() async throws {
        let (defaults, cleanup) = try defaults()
        defer { cleanup() }
        let diagnostics = SettingsDiagnostics()
        let host = EngineHost(makeEngine: { _ in LayoutEngine() })
        let listing = LayoutListing(models: [
            CleanupModelStatus(level: .light, name: "S1-mini by Superwhisper", sizeMB: 1447, status: .available, selected: true),
            CleanupModelStatus(level: .medium, name: "Gemma 4 E4B", sizeMB: 5150, status: .available, selected: false),
        ])
        let model = SetupModel(diagnostics: diagnostics, engine: host, cleanup: listing, defaults: defaults)

        diagnostics.microphoneStatus = .notDetermined
        try expectFits(model, "microphone: ask")
        diagnostics.microphoneStatus = .denied
        try expectFits(model, "microphone: denied")
        diagnostics.microphoneStatus = .authorized
        try expectFits(model, "microphone: prepare")
        _ = try await model.microphone.prepare { true }
        try expectFits(model, "accessibility")
        diagnostics.accessibilityGranted = true
        try expectFits(model, "speech: loading")
        await host.load()
        diagnostics.hotkeyHealth = .secureInputOn
        try expectFits(model, "shortcut: secure input")
        diagnostics.hotkeyHealth = .listening
        #expect(model.step == .models)
        try expectFits(model, "models: all available")
        listing.models[0].status = .failed(message: "The network connection was lost. Check your connection and try again.")
        listing.models[1].status = .downloading(ModelDownloadProgress(hubCompletedUnits: 612_000_000, hubTotalUnits: 1_447_000_000))
        try expectFits(model, "models: failed and downloading")
        model.finishModels()
        try expectFits(model, "ready")

        let failing = EngineHost(makeEngine: { _ in LayoutEngine(fails: true) })
        await failing.load()
        let failed = SetupModel(diagnostics: diagnostics, engine: failing, defaults: defaults)
        _ = try await failed.microphone.prepare { true }
        #expect(failed.step == .speech)
        try expectFits(failed, "speech: failed")
    }
}

private struct LayoutEngine: Transcriber {
    let id = "parakeet-tdt-v3"
    let displayName = "Layout only"
    var fails = false
    func prepare() async throws { if fails { throw CocoaError(.fileReadNoSuchFile) } }
    func transcribe(samples: [Float]) async throws -> Transcription { Transcription(text: "", processingSeconds: 0, engineID: id) }
}

@MainActor private final class LayoutListing: CleanupModelListing {
    var models: [CleanupModelStatus]
    init(models: [CleanupModelStatus]) { self.models = models }
    func cleanupModels() -> [CleanupModelStatus] { models }
    func downloadCleanupModel(_ level: CleanupLevel) {}
    func cancelCleanupDownload(_ level: CleanupLevel) {}
}
