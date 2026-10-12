import Synchronization

enum TapRole: Hashable, Sendable {
    /// Always on, listen-only: modifier changes.
    case flags
    /// Active: exists only while recording (or always, for the Fn remap and the probes).
    case keys
}

enum TapMessage: Sendable {
    case sample(TapRole, TapSample)
    case disabled(TapRole)
}

struct TapDecision: Equatable {
    var swallow: Bool
    var deliver: Bool

    static let passThrough = TapDecision(swallow: false, deliver: false)
    static let observe = TapDecision(swallow: false, deliver: true)
}

enum TapPolicy {
    static let escapeKeyCode: UInt16 = 53

    /// What the callback does with one event: whether to swallow it and whether to hand it off.
    static func decide(_ sample: TapSample, role: TapRole, recording: Bool, swallowedKey: UInt16?) -> TapDecision {
        // Our own posted events (the paste) are none of the hotkey's business.
        guard sample.userData != SyntheticEvents.stamp else { return .passThrough }
        guard role == .keys else { return .observe }
        guard sample.keyCode != HotkeyInputMapper.syntheticFnReleaseKeyCode else { return .passThrough }
        if sample.keyCode == escapeKeyCode, recording { return TapDecision(swallow: true, deliver: true) }
        if let swallowedKey, sample.keyCode == swallowedKey { return TapDecision(swallow: true, deliver: true) }
        return .observe
    }
}

/// What the C callback reads. Immutable except the atomic recording flag, so the callback takes no lock.
final class TapContext: Sendable {
    let role: TapRole
    let sink: AsyncStream<TapMessage>.Continuation
    let swallowedKey: UInt16?
    let recording = Atomic<Bool>(false)

    init(role: TapRole, sink: AsyncStream<TapMessage>.Continuation, swallowedKey: UInt16?) {
        self.role = role
        self.sink = sink
        self.swallowedKey = swallowedKey
    }
}
