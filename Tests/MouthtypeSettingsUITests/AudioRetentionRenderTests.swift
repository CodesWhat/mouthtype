import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct AudioRetentionRenderTests {
    @Test(arguments: ["light", "dark"])
    func retentionControlsRenderOffscreen(appearance: String) throws {
        let name = "RetentionRender-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        if appearance == "dark" { model.setAudioRetentionAge(.noAgeLimit); model.setAudioRetentionSize(.gb10) }
        let view = NSHostingView(
            rootView: AudioRetentionSection(model: model).padding(24).frame(width: 620, height: 310)
                .background(appearance == "dark" ? Color.black : Color.white)
                .environment(\.colorScheme, appearance == "dark" ? .dark : .light))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 310), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance == "dark" ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(NSSize(width: 620, height: 310))
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= 620 && bitmap.pixelsHigh >= 310)
        let padding = try #require(bitmap.colorAt(x: 5, y: 5))
        #expect(padding.alphaComponent == 1)
        #expect(view.window === window && !window.isVisible)
        if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
            let folder = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let data = try #require(bitmap.representation(using: .png, properties: [:]))
            try data.write(to: folder.appendingPathComponent("audio-retention-\(appearance).png"))
        }
    }
}
