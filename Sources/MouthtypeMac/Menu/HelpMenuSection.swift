import AppKit
import MouthtypeCore

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

    static func instructions(for shortcut: DictationShortcut?, mode: RecordingMode = .hold) -> String {
        let key = shortcut?.displayName ?? "Fn"
        var text = instructions.replacingOccurrences(of: "Fn", with: key)
        if mode == .toggle || shortcut?.isCapsLock == true {
            text = text.replacingOccurrences(of: "hold \(key) and speak, then release to paste", with: "press \(key) to start, speak, then press it again to stop and paste")
            if let paragraph = text.components(separatedBy: "\n\n").first(where: { $0.hasPrefix("For hands-free") }) {
                let detail = shortcut?.isCapsLock == true
                    ? "Caps Lock uses a toggle, not a hold. Its system Caps Lock state may also change."
                    : "Recording stays on after you release the shortcut."
                text = text.replacingOccurrences(of: paragraph, with: "\(detail) Press Esc to cancel; Undo stays available for 5 seconds.")
            }
        }
        if shortcut?.keyCode == 49 { text = text.replacingOccurrences(of: " or press \(key)+Space", with: "") }
        if shortcut?.keyCode == 53 { text = text.replacingOccurrences(of: "Press Esc to cancel", with: "Use Cancel Dictation in the menu to cancel hands-free recording") }
        return text
    }

    static func showGuide() {
        let alert = NSAlert()
        alert.messageText = "How to Use Mouthtype"
        alert.informativeText = instructions(for: ShortcutSettings.load(), mode: RecordingModePreference.current())
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
