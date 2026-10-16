import AppKit
import Testing
import SwiftUI
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SettingsWindowTests {
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

    @Test func cleanupEditsPersistWithoutChangingOtherPreferences() {
        let name = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var notifications = 0
        let model = SettingsModel(defaults: defaults, onCleanupChanged: { notifications += 1 })
        model.setLevel(.medium)
        model.setTone(.casual)
        model.setFillers(false)
        let saved = CleanupSettings.load(defaults)
        #expect(saved.level == .medium)
        #expect(saved.style == StylePreset.casual.options)
        #expect(!saved.fillers && saved.spokenCommands && saved.numbers)
        #expect(notifications == 3)
    }

    @Test func appearanceChangesUseExistingPreferencesAndLiveCallback() {
        let name = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var selected: [PillSkinKind] = []
        let model = SettingsModel(defaults: defaults, onSkinChanged: { selected.append($0) })
        model.setSkin(.hifi)
        model.setHiFiSize(.large)
        #expect(PillSkinPreference.current(defaults) == .hifi)
        #expect(HiFiPillSizePreference.current(defaults) == .large)
        #expect(selected == [.hifi, .hifi])
        model.setSounds(false)
        #expect(!SoundPreference.isEnabled(defaults))
    }

    @Test func refreshReflectsChangesMadeThroughTheMenu() {
        let name = "SettingsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        var cleanup = CleanupSettings.load(defaults)
        cleanup.style = StylePreset.veryCasual.options
        cleanup.save(to: defaults)
        SoundPreference.set(false, in: defaults)
        model.refresh()
        #expect(model.cleanup.style == StylePreset.veryCasual.options)
        #expect(!model.sounds)
    }

    @Test func appStyleEditsPreserveNewRulesAndUseDefaultOnRemoval() throws {
        let name = "SettingsAppTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        #expect(model.appStyles.entries.isEmpty)
        model.setAppStyle(bundleID: "com.apple.MobileSMS", appName: "Messages", tone: .casual)
        var external = try AppCleanupStyles.load(defaults)
        try external.set(bundleID: "com.tinyspeck.slackmacgap", appName: "Slack", style: StylePreset.formal.options)
        try external.save(to: defaults)
        model.setAppStyle(bundleID: "com.apple.MobileSMS", appName: "Messages", tone: .veryCasual)
        #expect(try AppCleanupStyles.load(defaults).entries.count == 2)
        model.removeAppStyle(bundleID: "com.apple.MobileSMS")
        #expect(model.appStyles.entries.map(\.appName) == ["Slack"])
        #expect(model.appStyles.resolve(bundleID: "com.apple.MobileSMS", fallback: .formal) == .formal)
    }

    @Test func malformedAppStylesCannotBeOverwrittenFromSettings() {
        let name = "SettingsAppTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let original = Data("malformed".utf8)
        defaults.set(original, forKey: AppCleanupStyles.preferenceKey)
        let model = SettingsModel(defaults: defaults)
        #expect(model.appStylesError != nil)
        model.setAppStyle(bundleID: "com.example.editor", appName: "Editor", tone: .formal)
        model.removeAppStyle(bundleID: "com.example.editor")
        #expect(defaults.data(forKey: AppCleanupStyles.preferenceKey) == original)
    }

    @Test func addingAnApplicationReadsItsIdentityAndKeepsCustomDefaultStyle() throws {
        let name = "SettingsPickerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = directory.appendingPathComponent("Editor.app")
        let contents = app.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": "com.example.editor", "CFBundleName": "Editor", "CFBundleDisplayName": "My Editor", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        var cleanup = CleanupSettings.load(defaults)
        cleanup.style = StyleOptions(capitalisation: .lowercase, endingPunctuation: .keep)
        cleanup.save(to: defaults)
        let model = SettingsModel(defaults: defaults)
        model.addApplication(at: app)
        let entry = try #require(model.appStyles.entries.first)
        #expect(entry.bundleID == "com.example.editor" && entry.appName == "My Editor")
        #expect(entry.style == cleanup.style)
        model.setAppStyle(bundleID: entry.bundleID, appName: entry.appName, tone: .casual)
        model.addApplication(at: app)
        #expect(model.appStyles.entries.first?.style == StylePreset.casual.options)
        model.addApplication(at: directory.appendingPathComponent("missing.app"))
        #expect(model.appStyles.entries.count == 1 && model.appStylesError != nil)
    }

    @Test func nativeApplicationMenuProvidesSettingsCloseAndTextEditing() throws {
        let section = SettingsMenuSection {}
        let menu = section.applicationMenu()
        let app = try #require(menu.items.first?.submenu)
        #expect(app.items.contains { $0.title == "Settings…" && $0.keyEquivalent == "," })
        let file = try #require(menu.items.first { $0.title == "File" }?.submenu)
        #expect(file.items.first?.action == #selector(NSWindow.performClose(_:)))
        #expect(file.items.first?.keyEquivalent == "w")
        let edit = try #require(menu.items.first { $0.title == "Edit" }?.submenu)
        #expect(edit.items.contains { $0.action == #selector(NSText.copy(_:)) && $0.keyEquivalent == "c" })
        #expect(edit.items.contains { $0.action == #selector(NSText.paste(_:)) && $0.keyEquivalent == "v" })
    }

    @Test func settingsMenuOpensTheOwnedWindow() throws {
        var opened = 0
        let section = SettingsMenuSection { opened += 1 }
        let item = try #require(section.items.first)
        #expect(item.title == "Settings…" && item.keyEquivalent == ",")
        _ = item.target?.perform(item.action, with: item)
        #expect(opened == 1)
    }
}
