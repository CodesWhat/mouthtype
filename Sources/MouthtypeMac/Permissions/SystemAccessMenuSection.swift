import AppKit

/// The menu lines for Accessibility, the hotkey tap's health, and a Globe key conflict.
@MainActor
public final class SystemAccessMenuSection: NSObject, MenuSection {
    private let accessibilityItem = NSMenuItem()
    private let hotkeyItem = NSMenuItem()
    private let globeItem = NSMenuItem()

    public var items: [NSMenuItem] { [accessibilityItem, hotkeyItem, globeItem] }

    public override init() {
        super.init()
        accessibilityItem.target = self
        accessibilityItem.action = #selector(openAccessibilitySettings)
        hotkeyItem.isEnabled = false
        globeItem.target = self
        globeItem.action = #selector(openKeyboardSettings)
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

    @objc private func openAccessibilitySettings() {
        NSWorkspace.shared.open(AccessibilityAccess.settingsURL)
    }

    @objc private func openKeyboardSettings() {
        NSWorkspace.shared.open(GlobeKeyCheck.settingsURL)
    }
}
