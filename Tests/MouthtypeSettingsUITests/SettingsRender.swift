import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// Offscreen Settings rendering. Glass cannot draw offscreen, so every render uses the solid sidebar.
@MainActor enum SettingsRender {
    /// The store every render uses unless a test passes its own: a temp directory and a fetch that always fails, so nothing touches
    /// the network or the real favicon cache.
    static let favicons = fakeFavicons()

    /// A store over a fresh temp directory with `icons` (host to image data) already on disk and a fetch that never leaves the process.
    static func fakeFavicons(icons: [String: Data] = [:]) -> SiteFaviconStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-render-favicons-\(UUID().uuidString)", isDirectory: true)
        if !icons.isEmpty {
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for (host, data) in icons { try? data.write(to: directory.appendingPathComponent(host + ".icon")) }
        }
        return SiteFaviconStore(directory: directory, fetch: { _ in throw URLError(.notConnectedToInternet) })
    }

    static func host(
        model: SettingsModel, actions: SettingsActions, dark: Bool,
        size: NSSize = SettingsTheme.windowSize, favicons: SiteFaviconStore = SettingsRender.favicons
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let view = NSHostingView(
            rootView: AnyView(
                SettingsView(model: model, actions: actions, solid: true)
                    .frame(width: size.width, height: size.height)
                    .environment(\.siteFavicons, favicons)
                    .environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    /// Any view hosted offscreen at `size` in a light or dark window, for the Settings modal and sheets (a real sheet cannot draw offscreen).
    static func host<Content: View>(
        _ content: Content, dark: Bool, size: NSSize, favicons: SiteFaviconStore = SettingsRender.favicons
    ) -> (NSHostingView<AnyView>, NSWindow) {
        let view = NSHostingView(
            rootView: AnyView(
                content.frame(width: size.width, height: size.height)
                    .environment(\.siteFavicons, favicons)
                    .environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    static func hostModal(model: SettingsModel, actions: SettingsActions, dark: Bool) -> (NSHostingView<AnyView>, NSWindow) {
        host(SettingsModalView(model: model, actions: actions), dark: dark, size: NSSize(width: SettingsModalView.size.width, height: SettingsModalView.size.height))
    }

    static func render<Content: View>(_ content: Content, dark: Bool, size: NSSize) throws -> NSBitmapImageRep {
        let (view, window) = host(content, dark: dark, size: size)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(!window.isVisible)
        return bitmap
    }

    static func renderModal(model: SettingsModel, actions: SettingsActions, dark: Bool) throws -> NSBitmapImageRep {
        try render(SettingsModalView(model: model, actions: actions), dark: dark, size: NSSize(width: SettingsModalView.size.width, height: SettingsModalView.size.height))
    }

    static func render(
        model: SettingsModel, actions: SettingsActions, dark: Bool,
        size: NSSize = SettingsTheme.windowSize
    ) throws -> NSBitmapImageRep {
        let (view, window) = host(model: model, actions: actions, dark: dark, size: size)
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(!window.isVisible)
        return bitmap
    }

    static func save(_ bitmap: NSBitmapImageRep, name: String) throws {
        guard let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] else { return }
        let url = URL(fileURLWithPath: directory, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: url.appendingPathComponent(name + ".png"))
    }
}
