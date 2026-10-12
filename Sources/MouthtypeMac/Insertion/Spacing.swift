// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// What comes right before the insertion point in the focused field, read
/// over Accessibility at delivery.
enum TextBeforeCursor: Equatable {
    /// The app did not say: no element, no selected range, or no text.
    case unknown
    /// The cursor is at the start of the field.
    case start
    /// The character just before the cursor, or before the selection a
    /// paste would replace.
    case character(Character)

    /// For the log, which never carries text: "letter", not the letter.
    var kind: String {
        switch self {
        case .unknown: return "unknown"
        case .start: return "start"
        case .character(let c) where c.isNewline: return "newline"
        case .character(let c) where c.isWhitespace: return "space"
        case .character(let c) where c.isLetter || c.isNumber: return "letter"
        case .character: return "punctuation"
        }
    }
}

/// The space before a transcript, so it doesn't run into the text already
/// there ("works well.The only thing"). Never a trailing one. Engines never
/// start or end a transcript with a space. Pure, so it is tested.
enum Spacing {
    /// Characters after which a word follows with no space: brackets and
    /// quotes that open, and the marks that start a handle or a path.
    private static let openers: Set<Character> = [
        "(", "[", "{", "<", "\"", "'", "“", "‘", "«", "‹", "¿", "¡", "/", "@", "#",
    ]

    /// Characters a transcript can start with that attach to the text before
    /// them: ", and then", "…".
    private static let attaching: Set<Character> = [
        ".", ",", ";", ":", "!", "?", ")", "]", "}", "…", "%", "”", "’", "»", "›",
    ]

    /// The text to insert. A leading space only when the app says the text
    /// before the cursor needs one, as after a word typed by hand. Unknown
    /// adds none.
    static func spaced(_ text: String, before: TextBeforeCursor) -> String {
        if case .character(let preceding) = before, needsSpace(after: preceding, text: text) {
            return " " + text
        }
        return text
    }

    /// Whether `text` needs a space to follow `preceding`.
    static func needsSpace(after preceding: Character, text: String) -> Bool {
        guard let first = text.first else { return false }
        if preceding.isWhitespace || first.isWhitespace { return false }
        if openers.contains(preceding) || attaching.contains(first) { return false }
        // Chinese, Japanese and Thai put no spaces between words.
        if isSpaceless(preceding) || isSpaceless(first) { return false }
        return true
    }

    private static func isSpaceless(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x0E00...0x0E7F, // Thai
             0x3000...0x303F, // CJK symbols and punctuation
             0x3040...0x30FF, // Hiragana and Katakana
             0x3400...0x4DBF, // CJK Extension A
             0x4E00...0x9FFF, // CJK Unified Ideographs
             0xFF00...0xFFEF, // Fullwidth forms
             0x20000...0x2FA1F: // CJK Extensions B and later
            return true
        default:
            return false
        }
    }
}
