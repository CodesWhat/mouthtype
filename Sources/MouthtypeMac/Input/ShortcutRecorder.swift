import Foundation
import CoreGraphics

@MainActor final class ShortcutRecorder {
    private(set) var draft: DictationShortcut?
    private(set) var isRecording = false
    private(set) var canSave = false
    private(set) var error: String?
    var onChange: (() -> Void)?
    private var state = ModifierState()
    private var pending: DictationShortcut?
    private var keyHeld = false
    private var priorDraft: DictationShortcut?
    private var priorCanSave = false

    var hint: String {
        if let error { return error }
        if isRecording { return "Press a key or combination, then release all keys. Use Cancel to leave without saving." }
        if draft?.isCapsLock == true { return "Caps Lock is a toggle: press once to start and again to stop. Its system Caps Lock state may also change." }
        return "Hold to talk and release to insert. Double-tap for hands-free. This shortcut is reserved for Mouthtype while it runs."
    }
    init(saved: DictationShortcut?) { draft = saved }
    func begin() {
        guard !isRecording else { return }
        priorDraft = draft
        priorCanSave = canSave
        state = ModifierState()
        pending = nil
        keyHeld = false
        isRecording = true
        canSave = false
        error = nil
        onChange?()
    }

    func receive(_ sample: TapSample, keyName: String? = nil) {
        guard isRecording, !sample.isAutorepeat, sample.userData != SyntheticEvents.stamp else { return }
        if sample.kind == .flagsChanged { state.apply(keyCode: sample.keyCode, flags: sample.flags) }
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let flags = (sample.flags & DictationShortcut.modifierMask & ~fn) | (state.fnHeld ? fn : 0)
        if sample.kind == .keyDown || (sample.kind == .flagsChanged && state.held.contains(sample.keyCode) && !keyHeld)
            || (sample.kind == .flagsChanged && sample.keyCode == 57) {
            let candidate = DictationShortcut(keyCode: sample.keyCode,
                modifiers: flags & ~DictationShortcut.modifierFlag(for: sample.keyCode),
                keyName: ShortcutKeyNames.name(for: sample.keyCode, characters: keyName))
            if candidate.isValid {
                pending = candidate
                draft = candidate.isDefault ? nil : candidate
                keyHeld = sample.kind == .keyDown
                error = nil
            } else { error = "That key could not be recorded. Try another key." }
        }
        if sample.kind == .keyUp, sample.keyCode == pending?.keyCode { keyHeld = false }
        if pending != nil, !keyHeld, state.held.isEmpty, flags == 0 {
            isRecording = false
            canSave = true
        }
        onChange?()
    }

    func cancelRecording() {
        guard isRecording else { return }
        isRecording = false
        draft = priorDraft
        canSave = priorCanSave
        error = nil
        onChange?()
    }
    func useDefault() {
        isRecording = false
        draft = nil
        canSave = true
        error = nil
        onChange?()
    }
    func save(_ apply: (DictationShortcut?) -> String?) -> Bool {
        guard canSave, !isRecording else { return false }
        error = apply(draft)
        onChange?()
        return error == nil
    }
}

enum ShortcutKeyNames {
    static func name(for code: UInt16, characters: String? = nil) -> String {
        let special: [UInt16: String] = [36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 53: "Escape", 54: "Right Command", 55: "Left Command",
            56: "Left Shift", 57: "Caps Lock", 58: "Left Option", 59: "Left Control", 60: "Right Shift", 61: "Right Option", 62: "Right Control",
            63: "Fn / Globe", 71: "Clear", 76: "Keypad Enter", 114: "Help", 115: "Home", 116: "Page Up", 117: "Forward Delete",
            119: "End", 121: "Page Down", 123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"]
        if let name = special[code] { return name }
        let functions: [UInt16] = [122,120,99,118,96,97,98,100,101,109,103,111,105,107,113,106,64,79,80,90]
        if let index = functions.firstIndex(of: code) { return "F\(index + 1)" }
        if let characters, !characters.isEmpty, characters.count <= 8,
           !characters.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || (0xF700...0xF8FF).contains($0.value) }) {
            return characters.uppercased()
        }
        return "Key \(code)"
    }
}
