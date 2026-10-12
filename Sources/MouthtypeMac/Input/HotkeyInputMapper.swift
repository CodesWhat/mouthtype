import MouthtypeCore

/// Where the hotkey comes from: the Fn flag, or (Fn remap mode) a remapped key's down and up.
public enum HotkeySource: Equatable, Sendable {
    case fnFlag
    case remapped(keyCode: UInt16)
}

extension Key {
    /// Stands in for "a key I can't name is held" when a press is refused, so the processor treats the chord as dirty.
    static let heldElsewhere = Key(code: 0xFFFF)
}

struct MappedInput: Equatable {
    var keyEvent: KeyEvent
    var timestampNanos: UInt64 // host nanoseconds, as `CGEvent.timestamp`
}

/// Turns tap samples into the processor's `KeyEvent`s. Pure, so it is tested without a live tap.
struct HotkeyInputMapper {
    /// macOS sends a synthetic keyDown with this code when Fn is released.
    static let syntheticFnReleaseKeyCode: UInt16 = 179

    let source: HotkeySource
    private(set) var state = ModifierState()
    private var remapKeyHeld = false
    /// A locked recording is open with no key down. Only Esc, which cancels it, is worth passing on then.
    var lockedRecording = false

    init(source: HotkeySource = .fnFlag) {
        self.source = source
    }

    var hotkeyHeld: Bool {
        switch source {
        case .fnFlag: state.fnHeld
        case .remapped: remapKeyHeld
        }
    }

    /// `otherKeysHeld` is asked only at the moment the hotkey goes down.
    mutating func map(_ sample: TapSample, otherKeysHeld: () -> Bool) -> MappedInput? {
        guard sample.userData != SyntheticEvents.stamp else { return nil }

        switch sample.kind {
        case .flagsChanged:
            let wasHeld = hotkeyHeld
            switch source {
            case .fnFlag: state.apply(keyCode: sample.keyCode, flags: sample.flags)
            case .remapped: state.apply(keyCode: sample.keyCode, flags: sample.flags, tracksFn: false)
            }
            return edge(wasHeld: wasHeld, sample, otherKeysHeld: otherKeysHeld)

        case .keyDown:
            guard sample.keyCode != Self.syntheticFnReleaseKeyCode, !sample.isAutorepeat else { return nil }
            if case let .remapped(destination) = source, sample.keyCode == destination {
                guard !remapKeyHeld else { return nil }
                remapKeyHeld = true
                return edge(wasHeld: false, sample, otherKeysHeld: otherKeysHeld)
            }
            // A key typed while the hotkey is up is none of the processor's business, and would leave it dirty.
            guard hotkeyHeld || (lockedRecording && sample.keyCode == TapPolicy.escapeKeyCode) else { return nil }
            return MappedInput(keyEvent: KeyEvent(key: Key(code: sample.keyCode), modifiers: composed), timestampNanos: sample.timestamp)

        case .keyUp:
            guard case let .remapped(destination) = source, sample.keyCode == destination, remapKeyHeld else { return nil }
            remapKeyHeld = false
            return edge(wasHeld: true, sample, otherKeysHeld: otherKeysHeld)
        }
    }

    private var composed: Modifiers {
        var set = state.modifiers
        if remapKeyHeld { set.insert(.fn) }
        return Modifiers(modifiers: set)
    }

    private func edge(wasHeld: Bool, _ sample: TapSample, otherKeysHeld: () -> Bool) -> MappedInput? {
        let isHeld = hotkeyHeld
        let refuse = !wasHeld && isHeld
            && (ModifierState.hasOtherModifierFlags(sample.flags) || otherKeysHeld())
        let key: Key? = refuse ? .heldElsewhere : nil
        // While the hotkey is up, still pass modifier changes on: the processor needs the full release to clear a dirty chord.
        return MappedInput(keyEvent: KeyEvent(key: key, modifiers: composed), timestampNanos: sample.timestamp)
    }
}
