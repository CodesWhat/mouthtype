import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// Offscreen Settings rendering. Glass cannot draw offscreen, so every render uses the solid sidebar.
@MainActor enum SettingsRender {
    static func host(model: SettingsModel, actions: SettingsActions, dark: Bool,
                     size: NSSize = SettingsTheme.windowSize) -> (NSHostingView<AnyView>, NSWindow) {
        let view = NSHostingView(rootView: AnyView(SettingsView(model: model, actions: actions, solid: true)
            .frame(width: size.width, height: size.height)
            .environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        return (view, window)
    }

    static func render(model: SettingsModel, actions: SettingsActions, dark: Bool,
                       size: NSSize = SettingsTheme.windowSize) throws -> NSBitmapImageRep {
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
