// Adapted from OpenWhispr (https://github.com/OpenWhispr/openwhispr, 5f9a88b), MIT License, Copyright (c) 2024 OpenWhispr Team.
import Carbon.HIToolbox
import CoreGraphics
import Foundation

/// Which virtual key types "v" under the keyboard layout in use.
@MainActor
protocol PasteKeyResolving: AnyObject {
    /// Nil when no key produces it. Never a guessed key code: on a non-QWERTY layout the wrong one is a different shortcut.
    func pasteKeyCode() -> CGKeyCode?
}

enum PasteKeyLookup {
    /// What a key code types under one layout, with the Command modifier held.
    typealias Translate = (UInt16) -> String?

    /// The first key code in 0..<128 that types `character`. An input method with no layout data of its own (CJK)
    /// falls back to the last ASCII-capable layout; a layout that has data but no such key is not second-guessed.
    static func keyCode(for character: String, current: Translate?, asciiCapable: () -> Translate?) -> CGKeyCode? {
        guard let translate = current ?? asciiCapable() else { return nil }
        for code in 0..<128 where translate(UInt16(code)) == character {
            return CGKeyCode(code)
        }
        return nil
    }
}

/// Reads the layout from Text Input Sources. Those calls belong on the main thread.
@MainActor
final class SystemPasteKeyResolver: PasteKeyResolving {
    /// The Command modifier as `UCKeyTranslate` wants it, so layouts that define their own Command table (Dvorak -
    /// QWERTY) give the key the app will match for Cmd+V.
    private static let commandModifierState = UInt32(cmdKey) >> 8

    func pasteKeyCode() -> CGKeyCode? {
        PasteKeyLookup.keyCode(
            for: "v",
            current: Self.translate(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()),
            asciiCapable: { Self.translate(TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue()) }
        )
    }

    private static func translate(_ source: TISInputSource?) -> PasteKeyLookup.Translate? {
        guard let source, let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue() as Data
        let keyboardType = UInt32(LMGetKbdType())
        return { keyCode in
            data.withUnsafeBytes { buffer in
                guard let base = buffer.baseAddress else { return nil }
                let layout = base.assumingMemoryBound(to: UCKeyboardLayout.self)
                var deadKeys: UInt32 = 0
                var length = 0
                var characters = [UniChar](repeating: 0, count: 4)
                let status = UCKeyTranslate(
                    layout, keyCode, UInt16(kUCKeyActionDisplay), commandModifierState, keyboardType,
                    OptionBits(kUCKeyTranslateNoDeadKeysBit), &deadKeys, characters.count, &length, &characters
                )
                guard status == noErr else { return nil }
                return String(utf16CodeUnits: characters, count: length)
            }
        }
    }
}
