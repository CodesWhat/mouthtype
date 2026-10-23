import CoreGraphics
import Foundation
import MouthtypeCore

/// An extra mouse button that can start dictation like the keyboard shortcut. Off by default.
public enum MouseTrigger: String, CaseIterable, Sendable {
    case none, middle, back, forward

    /// The `CGEvent` `mouseEventButtonNumber`: 0 and 1 are the left and right buttons, which are never offered.
    var buttonNumber: Int64? {
        switch self {
        case .none: nil
        case .middle: 2
        case .back: 3
        case .forward: 4
        }
    }

    var displayName: String {
        switch self {
        case .none: "None"
        case .middle: "Middle"
        case .back: "Back"
        case .forward: "Forward"
        }
    }
}

enum MouseTriggerPreference {
    static let key = "mouseTriggerButton"

    static func current(_ defaults: UserDefaults = .standard) -> MouseTrigger {
        guard let value = defaults.string(forKey: key), let trigger = MouseTrigger(rawValue: value) else { return .none }
        return trigger
    }

    static func set(_ value: MouseTrigger, in defaults: UserDefaults = .standard) {
        defaults.set(value.rawValue, forKey: key)
    }
}

/// A press or release of the chosen button, copied out of the tap callback.
struct MouseSample: Equatable, Sendable {
    var isDown: Bool
    var flags: UInt64
    var timestamp: UInt64
}

/// Turns the chosen button's presses into the processor's Fn-held `KeyEvent`s, so the mouse follows the keyboard
/// trigger's rules (minimum hold, double-tap lock, toggle, dirty-chord guards). Pure, so it is tested without a tap.
struct MouseInputMapper: Equatable {
    private(set) var held = false

    /// `otherKeysHeld` is asked only at the moment the button goes down.
    mutating func map(_ sample: MouseSample, otherKeysHeld: () -> Bool) -> MappedInput? {
        if sample.isDown {
            guard !held else { return nil }
            held = true
            let refuse = ModifierState.hasOtherModifierFlags(sample.flags) || otherKeysHeld()
            return MappedInput(
                keyEvent: KeyEvent(key: refuse ? .heldElsewhere : nil, modifiers: [.fn]), timestampNanos: sample.timestamp)
        }
        guard held else { return nil }
        held = false
        return MappedInput(keyEvent: KeyEvent(key: nil, modifiers: []), timestampNanos: sample.timestamp)
    }

    mutating func reset() { held = false }
}
