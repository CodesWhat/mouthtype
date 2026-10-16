import CoreGraphics
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

/// The key the Fn remap posts in place of an Fn combo that the remap broke.
struct FnCombo: Equatable, Sendable {
    var keyCode: UInt16
    /// Keypad Enter carries the numeric-pad flag; Page Up and friends do not.
    var keypad = false
}

/// The Fn combos that stop working once Fn is F19 at the HID layer, and what each stands in for.
enum FnCombos {
    static let spaceKeyCode: UInt16 = 49

    static let table: [UInt16: FnCombo] = [
        126: FnCombo(keyCode: 116), // Up -> Page Up
        125: FnCombo(keyCode: 121), // Down -> Page Down
        123: FnCombo(keyCode: 115), // Left -> Home
        124: FnCombo(keyCode: 119), // Right -> End
        51: FnCombo(keyCode: 117), // Delete -> Forward Delete
        36: FnCombo(keyCode: 76, keypad: true), // Return -> keypad Enter
    ]

    static func replacement(forKeyCode keyCode: UInt16, fnHeld: Bool) -> FnCombo? {
        fnHeld ? table[keyCode] : nil
    }

    /// The original's modifiers carried over. Arrows arrive flagged as keypad keys, which Page Up and the rest are
    /// not; the real Fn combos carry the Fn flag, so the replacement does too.
    static func flags(for combo: FnCombo, original: UInt64) -> UInt64 {
        let pad = CGEventFlags.maskNumericPad.rawValue
        var flags = original & ~pad
        flags |= CGEventFlags.maskSecondaryFn.rawValue
        if combo.keypad { flags |= pad }
        return flags
    }
}

/// What the tap thread owes a key whose down it consumed, so the up and the repeats follow it even if Fn came up first.
enum TapPending: Equatable, Sendable {
    case emulated(FnCombo)
    case swallowed
    case shortcut
}

struct TapDecision: Equatable {
    var swallow: Bool
    var deliver: Bool
    /// Post this in place of the swallowed event.
    var replacement: FnCombo?

    init(swallow: Bool, deliver: Bool, replacement: FnCombo? = nil) {
        self.swallow = swallow
        self.deliver = deliver
        self.replacement = replacement
    }

    static let passThrough = TapDecision(swallow: false, deliver: false)
    static let observe = TapDecision(swallow: false, deliver: true)
}

enum TapPolicy {
    static let escapeKeyCode: UInt16 = 53

    /// What the callback does with one event: whether to swallow it, whether to hand it off, and what to post instead.
    /// `swallowedKey` non-nil means Fn remap mode, which is also what turns on the Fn combo emulation.
    static func decide(
        _ sample: TapSample, role: TapRole, recording: Bool, swallowedKey: UInt16?,
        hotkeyHeld: Bool = false, pending: TapPending? = nil, idleKeysReported: Bool = true,
        shortcut: DictationShortcut? = nil, shortcutHeld: Bool = false
    ) -> TapDecision {
        // Our own posted events (the paste, the emulated combos) are none of the hotkey's business.
        guard sample.userData != SyntheticEvents.stamp else { return .passThrough }
        guard role == .keys else { return shortcut == nil ? .observe : .passThrough }
        guard sample.keyCode != HotkeyInputMapper.syntheticFnReleaseKeyCode else { return .passThrough }
        // The up and the repeats of a key whose down was consumed follow it, whether or not Fn is still down.
        if let pending, sample.kind == .keyUp || sample.isAutorepeat {
            if case let .emulated(combo) = pending { return TapDecision(swallow: true, deliver: false, replacement: combo) }
            if pending == .shortcut { return TapDecision(swallow: true, deliver: !sample.isAutorepeat) }
            return TapDecision(swallow: true, deliver: false)
        }
        if let shortcut {
            if sample.keyCode == shortcut.keyCode, hotkeyHeld || shortcutHeld {
                return TapDecision(swallow: true, deliver: true)
            }
            if sample.keyCode == escapeKeyCode, recording { return TapDecision(swallow: true, deliver: true) }
            if sample.kind == .keyDown, sample.keyCode == FnCombos.spaceKeyCode, hotkeyHeld, recording {
                return TapDecision(swallow: true, deliver: true)
            }
            return .observe
        }
        if sample.keyCode == escapeKeyCode, recording { return TapDecision(swallow: true, deliver: true) }
        if let swallowedKey, sample.keyCode == swallowedKey { return TapDecision(swallow: true, deliver: true) }
        if hotkeyHeld, sample.kind == .keyDown {
            if sample.keyCode == FnCombos.spaceKeyCode, recording { return TapDecision(swallow: true, deliver: true) }
            if swallowedKey != nil, let combo = FnCombos.replacement(forKeyCode: sample.keyCode, fnHeld: true) {
                // Delivered as a chord so the dictation Fn started is discarded; repeats don't need reporting again.
                return TapDecision(swallow: true, deliver: !sample.isAutorepeat, replacement: combo)
            }
        }
        return idleKeysReported || recording || hotkeyHeld ? .observe : .passThrough
    }

    /// Whether the event is the user typing or clicking, for the paste-spacing fallback. Our own posted events, the
    /// hotkey and events the tap swallowed for itself are not; an emulated Fn combo is, since its replacement reaches the app.
    static func countsAsUserInput(_ sample: TapSample, decision: TapDecision, swallowedKey: UInt16?) -> Bool {
        guard sample.kind == .keyDown, sample.userData != SyntheticEvents.stamp else { return false }
        guard sample.keyCode != swallowedKey, sample.keyCode != HotkeyInputMapper.syntheticFnReleaseKeyCode else { return false }
        return !decision.swallow || decision.replacement != nil
    }

    /// A mouse press, which counts as input but is never forwarded.
    static func isPointerDown(_ type: CGEventType) -> Bool {
        type == .leftMouseDown || type == .rightMouseDown || type == .otherMouseDown
    }

    /// Whether the hotkey is physically down after this event, or nil when the event says nothing about it.
    static func holdChange(_ sample: TapSample, swallowedKey: UInt16?, tracksFnFlag: Bool) -> Bool? {
        guard sample.userData != SyntheticEvents.stamp else { return nil }
        switch sample.kind {
        case .flagsChanged:
            return tracksFnFlag ? sample.flags & CGEventFlags.maskSecondaryFn.rawValue != 0 : nil
        case .keyDown:
            return swallowedKey == sample.keyCode ? true : nil
        case .keyUp:
            return swallowedKey == sample.keyCode ? false : nil
        }
    }

    enum PendingChange: Equatable {
        case none, set(TapPending), clear
    }

    static func pendingChange(for sample: TapSample, decision: TapDecision, shortcutKey: UInt16? = nil) -> PendingChange {
        switch sample.kind {
        case .flagsChanged: return .none
        case .keyUp: return .clear
        case .keyDown:
            guard !sample.isAutorepeat, decision.swallow, sample.userData != SyntheticEvents.stamp else { return .none }
            if sample.keyCode == shortcutKey { return .set(.shortcut) }
            if let replacement = decision.replacement { return .set(.emulated(replacement)) }
            return sample.keyCode == FnCombos.spaceKeyCode ? .set(.swallowed) : .none
        }
    }
}

/// State both taps and the main actor share. Atomics and one lock only the tap thread takes, so no callback waits on the main actor.
final class TapShared: Sendable {
    let recording = Atomic<Bool>(false)
    /// The hotkey is physically down, as the tap thread saw it.
    let hotkeyHeld = Atomic<Bool>(false)
    let pending = Mutex<[UInt16: TapPending]>([:])
    let shortcutMatcher = Mutex(ShortcutMatcher())
    // Counters for the self-test.
    let swallowed = Atomic<Int>(0)
    let emulated = Atomic<Int>(0)
    let stampedSeen = Atomic<Int>(0)
    /// Bumped on every real keyDown and mouse press, forwarded nowhere. Only ever increases.
    let userInput = Atomic<UInt64>(0)
    /// Whether the taps are installed in a way that sees all keys and clicks. When false the count says nothing.
    let inputTracked = Atomic<Bool>(false)

    /// The input count, or nil when the taps can't vouch for it.
    var userInputGeneration: UInt64? {
        inputTracked.load(ordering: .relaxed) ? userInput.load(ordering: .relaxed) : nil
    }

    func reset() {
        recording.store(false, ordering: .relaxed)
        hotkeyHeld.store(false, ordering: .relaxed)
        pending.withLock { $0.removeAll() }
        shortcutMatcher.withLock { $0 = ShortcutMatcher() }
    }
}

/// What the C callback reads. Immutable except the atomics in `shared`, so the callback takes no lock of its own.
final class TapContext: Sendable {
    let role: TapRole
    let sink: AsyncStream<TapMessage>.Continuation
    let swallowedKey: UInt16?
    let shared: TapShared
    /// Present on the key tap in remap mode only.
    let emulator: KeyEmulator?
    /// Fn flag mode: the hold is read off the Fn modifier flag.
    let tracksFnFlag: Bool
    /// Report keys typed while nothing is happening. Diagnostics only.
    let idleKeysReported: Bool
    /// The tap counts keystrokes itself (no other tap does), forwarding nothing. Flag tap only.
    let countsKeys: Bool
    let shortcut: DictationShortcut?

    func countPassiveKey(_ sample: TapSample) {
        if TapPolicy.countsAsUserInput(sample, decision: .passThrough, swallowedKey: swallowedKey) {
            shared.userInput.wrappingAdd(1, ordering: .relaxed)
        }
    }

    init(
        role: TapRole, sink: AsyncStream<TapMessage>.Continuation, swallowedKey: UInt16?, shared: TapShared,
        emulator: KeyEmulator? = nil, tracksFnFlag: Bool = false, idleKeysReported: Bool = false, countsKeys: Bool = false,
        shortcut: DictationShortcut? = nil
    ) {
        self.role = role
        self.sink = sink
        self.swallowedKey = swallowedKey
        self.shared = shared
        self.emulator = emulator
        self.tracksFnFlag = tracksFnFlag
        self.idleKeysReported = idleKeysReported
        self.countsKeys = countsKeys
        self.shortcut = shortcut
    }
}

/// Posts the replacement events from a private source, stamped so both taps pass them through. Used on the tap
/// thread only, inside the callback: posting there keeps the order of downs, repeats and ups by construction and
/// costs one event allocation, so no hand-off to another thread is needed.
final class KeyEmulator: @unchecked Sendable {
    private let source = CGEventSource(stateID: .privateState)

    @discardableResult
    func post(_ combo: FnCombo, keyDown: Bool, originalFlags: UInt64, autorepeat: Bool) -> Bool {
        guard let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(combo.keyCode), keyDown: keyDown) else {
            return false
        }
        event.flags = CGEventFlags(rawValue: FnCombos.flags(for: combo, original: originalFlags))
        event.setIntegerValueField(.keyboardEventAutorepeat, value: autorepeat ? 1 : 0)
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.stamp)
        event.post(tap: .cgSessionEventTap)
        return true
    }
}
