import AppKit
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SettingsWindowTests {
    @Test func audioRetentionControlsPersistAndRefreshWithoutChangingCleanup() {
        let name = "SettingsRetentionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let model = SettingsModel(defaults: defaults)
        let cleanup = model.cleanup
        #expect(model.audioRetention == AudioRetentionPolicy())
        model.setAudioRetentionAge(.days14)
        model.setAudioRetentionSize(.gb10)
        #expect(model.audioRetention == AudioRetentionPolicy(age: .days14, size: .gb10))
        #expect(AudioRetentionPreference.load(defaults) == model.audioRetention)
        AudioRetentionPreference.setAge(.noAgeLimit, in: defaults)
        model.refresh()
        #expect(model.audioRetention.age == .noAgeLimit)
        #expect(model.audioRetention.size == .gb10)
        #expect(model.cleanup == cleanup)
    }

    @Test func quietOtherAudioPersistsAndRefreshesWithoutChangingSounds() {
        let name = "SettingsQuietTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var changes: [Bool] = []
        let model = SettingsModel(defaults: defaults, onQuietOtherAudioChanged: { changes.append($0) })
        let sounds = model.sounds
        #expect(model.quietOtherAudio)
        model.setQuietOtherAudio(false)
        #expect(!model.quietOtherAudio)
        #expect(!QuietAudioPreference.isEnabled(defaults))
        model.setQuietOtherAudio(true)
        #expect(QuietAudioPreference.isEnabled(defaults))
        QuietAudioPreference.set(false, in: defaults)
        model.refresh()
        #expect(!model.quietOtherAudio)
        #expect(model.sounds == sounds)
        #expect(changes == [false, true])
    }

    @Test func explicitOffIsKeptAndUnsetIsOn() {
        let name = "SettingsQuietUnsetTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsModel(defaults: defaults).quietOtherAudio)
        defaults.set(false, forKey: QuietAudioPreference.key)
        #expect(!SettingsModel(defaults: defaults).quietOtherAudio)
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
        model.setPillSize(.large)
        #expect(PillSkinPreference.current(defaults) == .hifi)
        #expect(PillSizePreference.current(defaults) == .large && model.pillSize == .large)
        #expect(selected == [.hifi, .hifi])
        model.setSounds(false)
        #expect(!SoundPreference.isEnabled(defaults))
    }

    @Test func everyPillStylePersistsAndPreviews() {
        let name = "SettingsStyleTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var selected: [PillSkinKind] = []
        let model = SettingsModel(defaults: defaults, onSkinChanged: { selected.append($0) })
        #expect(model.skin == .classic)
        for kind in PillSkinKind.allCases {
            model.setSkin(kind)
            #expect(model.skin == kind && PillSkinPreference.current(defaults) == kind)
            #expect(SettingsPillImage.make(skin: kind, size: .standard) != nil)
            #expect(SettingsPillImage.make(skin: kind, size: .large) != nil)
        }
        #expect(selected == PillSkinKind.allCases)
    }

    @Test func fontOverridesRefreshPersistAndResetWithoutChangingOtherSettings() {
        let name = "SettingsFontTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        TextFontPreference.set(.custom("Menlo"), in: defaults)
        let model = SettingsModel(defaults: defaults)
        #expect(model.canResetFonts)
        model.setFontFamily("Avenir Next", for: .heading)
        model.setFontOverridesEnabled(true)
        #expect(model.fontOverrides.enabled)
        #expect(model.fontOverrides.families[.heading] == "Avenir Next")
        TextFontOverrides.setFamily("Menlo", for: .readout, in: defaults)
        model.setFontFamily("Avenir Next", for: .body)
        #expect(model.fontOverrides.families[.readout] == "Menlo")
        model.setFontOverridesEnabled(false)
        model.refresh()
        #expect(!model.fontOverrides.enabled)
        #expect(model.canResetFonts)
        #expect(model.fontOverrides.families[.heading] == "Avenir Next")
        #expect(model.font == .custom("Menlo"))
        model.setFont(.systema)
        #expect(model.canResetFonts)
        #expect(!model.fontFamilies.isEmpty)
        #expect(FontRegistry.families.allSatisfy { model.fontFamilies.contains($0) })
        model.setSounds(false)
        model.resetFonts()
        #expect(model.font == .systema && model.fontOverrides == TextFontOverrides())
        #expect(!model.canResetFonts)
        #expect(!model.sounds)
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
        let item = try #require(section.items.first { $0.title == "Settings…" })
        #expect(item.keyEquivalent == ",")
        _ = item.target?.perform(item.action, with: item)
        #expect(opened == 1)
    }
}
