import AppKit
import Testing
import SwiftUI
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct SettingsRenderTests {
    @Test func windowStartsOffscreenAndRendersEachPane() throws {
        let name = "SettingsRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        let controller = SettingsWindow(model: model)
        #expect(controller.window?.isVisible == false)
        #expect(controller.window?.title == "Mouthtype Settings")
        for page in SettingsPage.allCases {
            model.page = page
            controller.window?.contentView = NSHostingView(rootView: SettingsView(model: model).frame(width: 1000, height: 690))
            let view = try #require(controller.window?.contentView)
            view.setFrameSize(NSSize(width: 1000, height: 690))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            let image = try #require(bitmap.cgImage)
            #expect(image.width >= 1000 && image.height >= 690)
            if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: url.appendingPathComponent("settings-\(page.rawValue).png"))
            }
        }
        #expect(controller.window?.isVisible == false)
    }

    @Test func minimumWindowRendersAppRulesAndLargeHiFi() throws {
        let name = "SettingsMinimumTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var styles = AppCleanupStyles()
        try styles.set(bundleID: "com.apple.MobileSMS", appName: "Messages", style: StylePreset.casual.options)
        try styles.set(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: StylePreset.formal.options)
        try styles.save(to: defaults)
        PillSkinPreference.set(.hifi, in: defaults)
        HiFiPillSizePreference.set(.large, in: defaults)
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        let controller = SettingsWindow(model: model)
        controller.window?.setContentSize(NSSize(width: 860, height: 590))
        for page in [SettingsPage.writing, .appearance] {
            model.page = page
            controller.window?.contentView = NSHostingView(rootView: SettingsView(model: model).frame(width: 860, height: 590))
            let view = try #require(controller.window?.contentView)
            view.setFrameSize(NSSize(width: 860, height: 590))
            view.layoutSubtreeIfNeeded()
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 860 && bitmap.pixelsHigh >= 590)
            if let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_SETTINGS_PREVIEWS"] {
                let output = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let data = try #require(bitmap.representation(using: .png, properties: [:]))
                try data.write(to: output.appendingPathComponent("settings-\(page.rawValue)-minimum.png"))
            }
        }
        #expect(controller.window?.isVisible == false)
        #expect(model.appStyles.entries.count == 2 && model.hiFiSize == .large)
    }

}
