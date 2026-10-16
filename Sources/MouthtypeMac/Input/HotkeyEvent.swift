import MouthtypeCore

/// What the controller slice reacts to. Times are host nanoseconds (what `CGEvent.timestamp` reports), the same clock `AudioCapture.start(keyDownAtNanos:)` takes.
public enum HotkeyEvent: Equatable, Sendable {
    /// Fn went down. Start capturing now; the minimum hold is judged at release.
    case pressed(at: UInt64)
    /// Held long enough: stop capturing and transcribe.
    case released(at: UInt64)
    /// The recording in progress is now hands-free: no key is held and the next tap of the key ends it with `released`.
    case locked(at: UInt64, trigger: LockTrigger)
    /// Stop capturing and throw the audio away, with feedback.
    case cancelled(reason: CancelReason)
    /// Stop capturing and throw the audio away, silently (a short tap, or a chord).
    case discarded(reason: DiscardReason)
}

public enum HotkeyHealth: Equatable, Sendable {
    case listening
    case off
    case recovering
    case secureInputOn

    public var statusText: String {
        switch self {
        case .listening: "Hotkey: listening"
        case .off: "Hotkey: off"
        case .recovering: "Hotkey: recovering"
        case .secureInputOn: "Hotkey: secure input on"
        }
    }

    static func resolve(tapPresent: Bool, recovering: Bool, secureInput: Bool, recording: Bool) -> HotkeyHealth {
        guard tapPresent else { return .off }
        if recovering { return .recovering }
        if secureInput, !recording { return .secureInputOn }
        return .listening
    }
}

extension LockTrigger {
    var dictationTrigger: DictationTrigger {
        switch self {
        case .doubleTap: .doubleTap
        case .fnSpace: .fnSpace
        case .toggle: .toggle
        }
    }
}
