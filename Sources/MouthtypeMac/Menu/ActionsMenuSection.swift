import AppKit

/// Paste Last, Copy Last, and the Sounds and Launch at Login switches.
@MainActor
final class ActionsMenuSection: NSObject, MenuSection {
    private let defaults: UserDefaults
    private let loginItem: LoginItem
    private let onPasteLast: @MainActor () -> Void
    private let onCopyLast: @MainActor () -> Void
    private let pasteItem = NSMenuItem(title: "Paste Last", action: nil, keyEquivalent: "v")
    private let copyItem = NSMenuItem(title: "Copy Last", action: nil, keyEquivalent: "c")
    private let soundsItem = NSMenuItem(title: "Sounds", action: nil, keyEquivalent: "")
    private let loginItemItem = NSMenuItem(title: "Launch at Login", action: nil, keyEquivalent: "")

    var items: [NSMenuItem] { [pasteItem, copyItem, soundsItem, loginItemItem] }

    init(
        defaults: UserDefaults = .standard, loginItem: LoginItem = LoginItem(),
        onPasteLast: @escaping @MainActor () -> Void, onCopyLast: @escaping @MainActor () -> Void
    ) {
        self.defaults = defaults
        self.loginItem = loginItem
        self.onPasteLast = onPasteLast
        self.onCopyLast = onCopyLast
        super.init()
        for item in [pasteItem, copyItem] {
            item.keyEquivalentModifierMask = [.command, .control]
            item.target = self
        }
        pasteItem.action = #selector(pasteLast)
        copyItem.action = #selector(copyLast)
        soundsItem.target = self
        soundsItem.action = #selector(toggleSounds)
        loginItemItem.target = self
        loginItemItem.action = #selector(toggleLogin)
        refresh()
    }

    func refresh() {
        soundsItem.state = SoundPreference.isEnabled(defaults) ? .on : .off
        loginItemItem.state = loginItem.menuState
    }

    @objc private func pasteLast() { onPasteLast() }
    @objc private func copyLast() { onCopyLast() }

    @objc private func toggleSounds() {
        SoundPreference.set(!SoundPreference.isEnabled(defaults), in: defaults)
        refresh()
    }

    @objc private func toggleLogin() {
        loginItem.toggle()
        refresh()
    }
}
