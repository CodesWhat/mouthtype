import AppKit

@MainActor
final class HelpMenuSection: NSObject, MenuSection {
    static let instructions = """
        Allow Microphone and Accessibility access in System Settings.

        Click a text field, hold Fn and speak, then release to paste.

        For hands-free dictation, double-tap Fn or press Fn+Space. Tap Fn to stop. Press Esc to cancel; Undo stays available for 5 seconds.

        Speech is transcribed on this Mac. Models download when needed. Text history stays on this Mac. Audio cleanup at launch removes recordings older than 90 days, then the oldest until the archive fits within 2 GB.
        """
    private let item = NSMenuItem(title: "How to Use Mouthtype…", action: nil, keyEquivalent: "")
    private let onShow: @MainActor () -> Void
    var items: [NSMenuItem] { [item] }

    init(onShow: @escaping @MainActor () -> Void = HelpMenuSection.showGuide) {
        self.onShow = onShow
        super.init()
        item.target = self
        item.action = #selector(show)
    }

    @objc private func show() { onShow() }

    static func showGuide() {
        let alert = NSAlert()
        alert.messageText = "How to Use Mouthtype"
        alert.informativeText = instructions
        alert.addButton(withTitle: "Done")
        alert.addButton(withTitle: "Microphone Settings")
        alert.addButton(withTitle: "Accessibility Settings")
        NSApp.activate()
        switch alert.runModal() {
        case .alertSecondButtonReturn: NSWorkspace.shared.open(MicrophoneAccess.settingsURL)
        case .alertThirdButtonReturn: NSWorkspace.shared.open(AccessibilityAccess.settingsURL)
        default: break
        }
    }
}
