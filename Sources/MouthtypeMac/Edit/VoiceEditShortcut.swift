import Carbon.HIToolbox
import Foundation

/// The optional global shortcut for Edit Selection by Voice. Unset by default. A short list of combinations that don't
/// collide with the dictation shortcut or Paste Last / Copy Last, so there is nothing to record or validate.
enum VoiceEditShortcut: String, CaseIterable {
    case off, controlOptionE, controlOptionCommandE

    static let preferenceKey = "voiceEditShortcut"

    var displayName: String {
        switch self {
        case .off: "Off"
        case .controlOptionE: "⌃⌥E"
        case .controlOptionCommandE: "⌃⌥⌘E"
        }
    }

    var shortcut: GlobalShortcuts.Shortcut? {
        switch self {
        case .off: nil
        case .controlOptionE: GlobalShortcuts.Shortcut(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey)
        case .controlOptionCommandE:
            GlobalShortcuts.Shortcut(keyCode: kVK_ANSI_E, modifiers: controlKey | optionKey | cmdKey)
        }
    }

    static func current(_ defaults: UserDefaults = .standard) -> VoiceEditShortcut {
        defaults.string(forKey: preferenceKey).flatMap(VoiceEditShortcut.init(rawValue:)) ?? .off
    }

    static func set(_ value: VoiceEditShortcut, in defaults: UserDefaults = .standard) {
        if value == .off { defaults.removeObject(forKey: preferenceKey) } else { defaults.set(value.rawValue, forKey: preferenceKey) }
    }
}
