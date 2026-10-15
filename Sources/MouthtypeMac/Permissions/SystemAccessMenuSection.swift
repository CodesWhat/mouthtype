import AppKit

/// The menu lines for Accessibility, the hotkey tap's health, a Globe key conflict, and the Fn remap switch.
@MainActor
public final class SystemAccessMenuSection: NSObject, MenuSection {
    private let accessibilityItem = NSMenuItem()
    private let hotkeyItem = NSMenuItem()
    private let globeItem = NSMenuItem()
    private let remapItem = NSMenuItem(title: "Remap Fn key (hides the emoji picker)", action: nil, keyEquivalent: "")
    private let shortcutItem = NSMenuItem(title: "Change Dictation Shortcut…", action: nil, keyEquivalent: "")
    private var shortcut: DictationShortcut?
    private var health: HotkeyHealth = .off

    /// A click on the remap checkbox.
    public var onToggleRemap: (@MainActor () -> Void)?
    public var onChangeShortcut: (@MainActor () -> Void)?
    public func update(shortcut: DictationShortcut?) {
        self.shortcut = shortcut
        remapItem.isHidden = shortcut != nil
        if shortcut != nil { globeItem.isHidden = true }
        update(hotkeyHealth: health)
    }

    public var items: [NSMenuItem] { [accessibilityItem, hotkeyItem, globeItem, remapItem, shortcutItem] }

    public override init() {
        super.init()
        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibilitySettings)
        hotkeyItem.isEnabled = false
        shortcutItem.target = self
        shortcutItem.action = #selector(changeShortcut)
        globeItem.target = self
        globeItem.action = #selector(openKeyboardSettings)
        remapItem.target = self
        remapItem.action = #selector(toggleRemap)
        update(accessibilityGranted: false)
        update(hotkeyHealth: .off)
        update(globe: nil)
    }

    public func update(accessibilityGranted granted: Bool) {
        accessibilityItem.title = AccessibilityAccess.statusText(granted: granted)
        // Granted reads as a status line; needed is the one that does something when clicked.
        accessibilityItem.action = granted ? nil : #selector(openAccessibilitySettings)
        accessibilityItem.isEnabled = !granted
    }

    public func update(hotkeyHealth health: HotkeyHealth) {
        self.health = health
        let status = health.statusText.replacingOccurrences(of: "Hotkey:", with: "Dictation input:")
            .replacingOccurrences(of: "listening", with: "active")
        hotkeyItem.title = status + " · " + (shortcut?.displayName ?? "Fn / Globe")
    }

    public func update(globe: GlobeKeyCheck?) {
        let text = globe?.menuText
        globeItem.title = text ?? ""
        globeItem.isHidden = text == nil || shortcut != nil
    }

    public func update(remapChecked checked: Bool) {
        remapItem.state = checked ? .on : .off
    }

    @objc private func toggleRemap() {
        onToggleRemap?()
    }

    @objc private func changeShortcut() { onChangeShortcut?() }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(AccessibilityAccess.settingsURL)
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(GlobeKeyCheck.settingsURL)
    }
}
