import AppKit
import MouthtypeCore
import Observation
import UniformTypeIdentifiers

@MainActor @Observable final class SettingsModel {
    private let defaults: UserDefaults
    private let loginItem: LoginItem
    private let onCleanupChanged: @MainActor () -> Void
    private let onSkinChanged: @MainActor (PillSkinKind) -> Void
    var page = SettingsPage.general
    private(set) var cleanup: CleanupSettings
    private(set) var sounds: Bool
    private(set) var skin: PillSkinKind
    private(set) var hiFiSize: HiFiPillSize
    private(set) var font: TextFontChoice
    private(set) var loginState: NSControl.StateValue = .off
    private(set) var shortcut = "Fn"
    private(set) var appStyles = AppCleanupStyles()
    private(set) var appStylesError: String?

    init(defaults: UserDefaults = .standard, loginItem: LoginItem = LoginItem(),
         onCleanupChanged: @escaping @MainActor () -> Void = {},
         onSkinChanged: @escaping @MainActor (PillSkinKind) -> Void = { _ in }) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.onCleanupChanged = onCleanupChanged
        self.onSkinChanged = onSkinChanged
        cleanup = CleanupSettings.load(defaults)
        sounds = SoundPreference.isEnabled(defaults)
        skin = PillSkinPreference.current(defaults)
        hiFiSize = HiFiPillSizePreference.current(defaults)
        font = TextFontPreference.current(defaults)
        refresh()
    }

    func refresh() {
        cleanup = CleanupSettings.load(defaults)
        sounds = SoundPreference.isEnabled(defaults)
        skin = PillSkinPreference.current(defaults)
        hiFiSize = HiFiPillSizePreference.current(defaults)
        font = TextFontPreference.current(defaults)
        shortcut = ShortcutSettings.load(defaults)?.displayName ?? "Fn"
        loginState = loginItem.menuState
        do { appStyles = try AppCleanupStyles.load(defaults); appStylesError = nil }
        catch { appStylesError = error.localizedDescription }
    }

    private func updateAppStyles(_ change: (inout AppCleanupStyles) throws -> Void) {
        do {
            var current = try AppCleanupStyles.load(defaults)
            try change(&current)
            try current.save(to: defaults)
            appStyles = current
            appStylesError = nil
        } catch { appStylesError = error.localizedDescription }
    }

    func setAppStyle(bundleID: String, appName: String, tone: StylePreset) {
        updateAppStyles { try $0.set(bundleID: bundleID, appName: appName, style: tone.options) }
    }

    func removeAppStyle(bundleID: String) { updateAppStyles { $0.remove(bundleID: bundleID) } }

    func chooseApplication() {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Add application"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addApplication(at: url)
        }
    }

    func addApplication(at url: URL) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            appStylesError = "That application has no readable bundle identifier."
            return
        }
        let appName = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        let style = CleanupSettings.load(defaults).style
        updateAppStyles {
            guard !$0.entries.contains(where: { $0.bundleID == bundleID }) else { return }
            try $0.set(bundleID: bundleID, appName: appName, style: style)
        }
    }

    private func update(_ change: (inout CleanupSettings) -> Void) {
        var current = CleanupSettings.load(defaults)
        change(&current)
        current.save(to: defaults)
        cleanup = current
        onCleanupChanged()
    }

    func setLevel(_ level: CleanupLevel) { update { $0.level = level } }
    func setTone(_ tone: StylePreset) { update { $0.style = tone.options } }
    func setFillers(_ value: Bool) { update { $0.fillers = value } }
    func setSpokenCommands(_ value: Bool) { update { $0.spokenCommands = value } }
    func setNumbers(_ value: Bool) { update { $0.numbers = value } }
    func setSounds(_ value: Bool) { SoundPreference.set(value, in: defaults); sounds = value }
    func toggleLogin() { loginItem.toggle(); loginState = loginItem.menuState }
    func setSkin(_ value: PillSkinKind) {
        PillSkinPreference.set(value, in: defaults)
        skin = value
        onSkinChanged(value)
    }
    func setHiFiSize(_ value: HiFiPillSize) {
        HiFiPillSizePreference.set(value, in: defaults)
        hiFiSize = value
        setSkin(.hifi)
    }
    func setFont(_ value: TextFontChoice) {
        TextFontPreference.set(value, in: defaults)
        font = value
    }
}
