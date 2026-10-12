import AppKit

/// The menu lines for Accessibility, the hotkey tap's health, a Globe key conflict, and the Fn remap switch.
@MainActor
public final class SystemAccessMenuSection: NSObject, MenuSection {
    private let accessibilityItem = NSMenuItem()
    private let hotkeyItem = NSMenuItem()
    private let globeItem = NSMenuItem()
    private let remapItem = NSMenuItem(title: "Remap Fn key (hides the emoji picker)", action: nil, keyEquivalent: "")

    /// A click on the remap checkbox.
    public var onToggleRemap: (@MainActor () -> Void)?

    public var items: [NSMenuItem] { [accessibilityItem, hotkeyItem, globeItem, remapItem] }

    public override init() {
        super.init()
        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibilitySettings)
        hotkeyItem.isEnabled = false
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
        hotkeyItem.title = health.statusText
    }

    public func update(globe: GlobeKeyCheck?) {
        let text = globe?.menuText
        globeItem.title = text ?? ""
        globeItem.isHidden = text == nil
    }

    public func update(remapChecked checked: Bool) {
        remapItem.state = checked ? .on : .off
    }

    @objc private func toggleRemap() {
        onToggleRemap?()
    }

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(AccessibilityAccess.settingsURL)
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(GlobeKeyCheck.settingsURL)
    }
}
