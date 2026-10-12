import CoreGraphics
import MouthtypeCore

/// Which modifier keys are down, tracked by key code so left and right stay distinct
/// (they share one flag bit). Only `flagsChanged` events feed it: arrow and function keys
/// carry the fn flag even when fn isn't held, so a keyDown's flags say nothing about fn.
struct ModifierState: Equatable {
    static let fnKeyCode: UInt16 = 63
    static let capsLockKeyCode: UInt16 = 57

    private static let sided: [UInt16: Modifier] = [
        55: Modifier(kind: .command, side: .left), 54: Modifier(kind: .command, side: .right),
        56: Modifier(kind: .shift, side: .left), 60: Modifier(kind: .shift, side: .right),
        58: Modifier(kind: .option, side: .left), 61: Modifier(kind: .option, side: .right),
        59: Modifier(kind: .control, side: .left), 62: Modifier(kind: .control, side: .right),
    ]

    private static let fnFlag = CGEventFlags.maskSecondaryFn.rawValue
    private static let otherFlags: UInt64 = [CGEventFlags.maskShift, .maskControl, .maskAlternate, .maskCommand].reduce(0) { $0 | $1.rawValue }

    static func isModifierKeyCode(_ code: UInt16) -> Bool {
        code == fnKeyCode || code == capsLockKeyCode || sided[code] != nil
    }

    static func hasOtherModifierFlags(_ flags: UInt64) -> Bool {
        flags & otherFlags != 0
    }

    private static func flag(for kind: Modifier.Kind) -> UInt64 {
        switch kind {
        case .shift: CGEventFlags.maskShift.rawValue
        case .control: CGEventFlags.maskControl.rawValue
        case .option: CGEventFlags.maskAlternate.rawValue
        case .command: CGEventFlags.maskCommand.rawValue
        case .fn: fnFlag
        }
    }

    private(set) var held: Set<UInt16> = []

    var fnHeld: Bool { held.contains(Self.fnKeyCode) }

    mutating func apply(keyCode: UInt16, flags: UInt64, tracksFn: Bool = true) {
        // A kind whose flag is clear has no key down, which also repairs a release we never saw.
        for (code, modifier) in Self.sided where flags & Self.flag(for: modifier.kind) == 0 {
            held.remove(code)
        }
        if let modifier = Self.sided[keyCode], flags & Self.flag(for: modifier.kind) != 0 {
            // The flag survives while the other side is down, so a repeat event for a held key is its release.
            if held.contains(keyCode) { held.remove(keyCode) } else { held.insert(keyCode) }
        }
        if tracksFn {
            if flags & Self.fnFlag != 0 { held.insert(Self.fnKeyCode) } else { held.remove(Self.fnKeyCode) }
        }
    }

    var modifiers: Set<Modifier> {
        var result = Set<Modifier>()
        for code in held {
            if code == Self.fnKeyCode { result.insert(.fn) } else if let modifier = Self.sided[code] { result.insert(modifier) }
        }
        return result
    }
}
