import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// Glass in the Appearance preview over each swatch. Set MOUTHTYPE_GLASS_PREVIEW_DIR to write PNGs; the shown-window
/// capture also needs that variable, since it asks the window server for the real composited pixels.
@MainActor @Suite(.serialized) struct GlassPreviewRenderTests {
    private var outputDirectory: URL? {
        ProcessInfo.processInfo.environment["MOUTHTYPE_GLASS_PREVIEW_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) }
    }

    private func model(wallpaper: PreviewWallpaper) -> (SettingsModel, UserDefaults, String) {
        let name = "GlassPreviewRender-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        PillSkinPreference.set(.glass, in: defaults)
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        model.page = .appearance
        model.previewWallpaper = wallpaper
        return (model, defaults, name)
    }

    private func write(_ bitmap: NSBitmapImageRep, _ name: String) throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: directory.appendingPathComponent(name + ".png"))
    }

    private func wait(_ seconds: TimeInterval) async { try? await Task.sleep(for: .seconds(seconds)) }

    @Test(arguments: PreviewWallpaper.allCases)
    func glassRendersOffscreenOverEachSwatch(wallpaper: PreviewWallpaper) async throws {
        let (model, defaults, name) = model(wallpaper: wallpaper)
        defer { defaults.removePersistentDomain(forName: name) }
        let (view, _) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
        await wait(1.0)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try write(bitmap, "offscreen-\(wallpaper.rawValue)")
    }

    /// The real Settings content in a shown window, captured from the window server so the NSGlassEffectView material is
    /// composited. Skipped unless an output directory is given.
    @Test(arguments: PreviewWallpaper.allCases)
    func glassInAShownWindowOverEachSwatch(wallpaper: PreviewWallpaper) async throws {
        guard let directory = outputDirectory else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (model, defaults, name) = model(wallpaper: wallpaper)
        defer { defaults.removePersistentDomain(forName: name) }
        let size = SettingsTheme.windowSize
        let settings = SettingsView(model: model, actions: SettingsActions(), solid: true, favicons: SettingsRender.favicons)
        let host = NSHostingView(rootView: AnyView(settings.frame(width: size.width, height: size.height)))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 120, y: 120), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        defer { window.orderOut(nil); window.close() }
        await wait(2.0)
        let file = directory.appendingPathComponent("window-\(wallpaper.rawValue).png")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        process.arguments = ["-x", "-o", "-l", String(window.windowNumber), file.path]
        try process.run()
        process.waitUntilExit()
        print("screencapture \(wallpaper.rawValue) exit \(process.terminationStatus) exists \(FileManager.default.fileExists(atPath: file.path))")
    }
}
