import CoreGraphics
import Foundation

public struct DictationShortcut: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64
    public var keyName: String

    static let modifierMask: UInt64 = [CGEventFlags.maskControl, .maskAlternate, .maskShift, .maskCommand, .maskSecondaryFn].reduce(0) { $0 | $1.rawValue }

    public init(keyCode: UInt16, modifiers: UInt64 = 0, keyName: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.keyName = keyName
    }

    static func modifierFlag(for code: UInt16) -> UInt64 {
        switch code {
        case 54, 55: CGEventFlags.maskCommand.rawValue
        case 56, 60: CGEventFlags.maskShift.rawValue
        case 58, 61: CGEventFlags.maskAlternate.rawValue
        case 59, 62: CGEventFlags.maskControl.rawValue
        case 63: CGEventFlags.maskSecondaryFn.rawValue
        default: 0
        }
    }

    var requiredFlags: UInt64 { modifiers | Self.modifierFlag(for: keyCode) }
    var isModifier: Bool { Self.modifierFlag(for: keyCode) != 0 }
    var isCapsLock: Bool { keyCode == 57 }
    var isDefault: Bool { keyCode == 63 && modifiers == 0 }
    func claimsLastAction(keyCode: Int) -> Bool {
        Int(self.keyCode) == keyCode && modifiers == CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue
    }
    var isValid: Bool {
        keyCode < 128 && modifiers & ~Self.modifierMask == 0 && modifiers & Self.modifierFlag(for: keyCode) == 0
            && !keyName.isEmpty && keyName.count <= 40 && !keyName.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
    var displayName: String {
        let flags: [(UInt64, String)] = [(CGEventFlags.maskControl.rawValue, "⌃"), (CGEventFlags.maskAlternate.rawValue, "⌥"),
            (CGEventFlags.maskShift.rawValue, "⇧"), (CGEventFlags.maskCommand.rawValue, "⌘"), (CGEventFlags.maskSecondaryFn.rawValue, "Fn+")]
        return flags.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + keyName
    }
}

enum ShortcutSettings {
    static let preferenceKey = "dictationShortcut"
    static func apply(_ shortcut: DictationShortcut?, in defaults: UserDefaults = .standard,
                      activate: (DictationShortcut?) -> String?) -> String? {
        if let shortcut, !shortcut.isValid { return "That shortcut is not valid. Record another key." }
        if let error = activate(shortcut) { return error }
        _ = save(shortcut, in: defaults)
        return nil
    }

    static func load(_ defaults: UserDefaults = .standard) -> DictationShortcut? {
        guard let data = defaults.data(forKey: preferenceKey),
              let shortcut = try? JSONDecoder().decode(DictationShortcut.self, from: data), shortcut.isValid, !shortcut.isDefault else { return nil }
        return shortcut
    }

    @discardableResult static func save(_ shortcut: DictationShortcut?, in defaults: UserDefaults = .standard) -> Bool {
        guard let shortcut, !shortcut.isDefault else { defaults.removeObject(forKey: preferenceKey); return true }
        guard shortcut.isValid, let data = try? JSONEncoder().encode(shortcut) else { return false }
        defaults.set(data, forKey: preferenceKey)
        return true
    }
}

struct ShortcutMatcher: Sendable {
    private(set) var held = false
    private var state = ModifierState()
    private var blocked = false

    mutating func update(_ sample: TapSample, shortcut: DictationShortcut) -> Bool {
        guard sample.userData != SyntheticEvents.stamp, !sample.isAutorepeat else { return held }
        if sample.kind == .flagsChanged { state.apply(keyCode: sample.keyCode, flags: sample.flags) }
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let flags = (sample.flags & DictationShortcut.modifierMask & ~fn) | (state.fnHeld ? fn : 0)
        if shortcut.isCapsLock {
            if sample.kind == .flagsChanged, sample.keyCode == 57, flags == shortcut.modifiers { held.toggle() }
        } else if shortcut.isModifier {
            if flags & ~shortcut.requiredFlags != 0 { blocked = true }
            if state.held.isEmpty { blocked = false }
            held = !blocked && state.held.contains(shortcut.keyCode) && flags == shortcut.requiredFlags
        } else {
            if sample.kind == .keyDown, sample.keyCode == shortcut.keyCode { held = flags == shortcut.modifiers }
            if sample.kind == .keyUp, sample.keyCode == shortcut.keyCode { held = false }
            if flags & shortcut.modifiers != shortcut.modifiers { held = false }
        }
        return held
    }
}
