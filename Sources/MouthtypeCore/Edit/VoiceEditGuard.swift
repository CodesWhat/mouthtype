import Foundation

/// Why a voice edit's output was not offered as a replacement.
public enum VoiceEditRefusal: Sendable, Equatable {
    case emptySelection
    case emptyInstruction
    case emptyOutput
    case unchanged
    /// The model said it won't or can't, or answered with the unsupported-request sentinel.
    case modelDeclined
    /// The output talks about the edit ("Here is ...") instead of being the edited text.
    case chatter
    case echoesPromptFraming
    case echoesInstruction
    case controlCharacters
    case tooLong
    /// The instruction asked to shorten and the output isn't shorter.
    case notShorter
}

public enum VoiceEditVerdict: Sendable, Equatable {
    case accepted(String)
    case refused(VoiceEditRefusal)
}

/// Judges a voice edit's output against its selection and instruction. Separate from `SmartCleanupGuard` on purpose:
/// a requested rephrase can differ heavily from the selection, so there is no similarity or kept-words threshold here.
/// The checks are about the output being a plausible edit and not a reply, an echo or a runaway.
public enum VoiceEditGuard {
    /// Characters allowed for the output: four times the selection, or 500 more than it, whichever is larger.
    public static func maximumLength(forSelectionLength length: Int) -> Int { max(4 * length, length + 500) }

    public static func judge(selection: String, instruction: String, output: String) -> VoiceEditVerdict {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(.emptyOutput) }
        if declines(trimmed) { return .refused(.modelDeclined) }
        if hasPreamble(trimmed, selection: selection) { return .refused(.chatter) }
        if hasDisallowedControl(output) { return .refused(.controlCharacters) }
        if trimmed.contains(VoiceEditPrompt.delimiterPrefix), !selection.contains(VoiceEditPrompt.delimiterPrefix) {
            return .refused(.echoesPromptFraming)
        }
        if echoes(instruction: instruction, in: trimmed, selection: selection) { return .refused(.echoesInstruction) }
        if output.count > maximumLength(forSelectionLength: selection.count) { return .refused(.tooLong) }
        let source = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == source { return .refused(.unchanged) }
        if asksToShorten(instruction), trimmed.count >= source.count { return .refused(.notShorter) }
        return .accepted(trimmed)
    }

    private static func declines(_ text: String) -> Bool {
        if text.contains(VoiceEditPrompt.unsupportedSentinel) { return true }
        let lower = text.lowercased()
        let openers = [
            "i'm sorry", "i’m sorry", "i am sorry", "sorry,", "i can't", "i can’t", "i cannot", "i can not", "i'm unable",
            "i’m unable", "i am unable", "i won't", "i’m not able", "i'm not able", "as an ai", "unfortunately",
        ]
        return openers.contains { lower.hasPrefix($0) }
    }

    /// Framing that talks about the edit. Matched only at the start, so "Here is" inside a rewritten sentence passes, and
    /// not matched when the selection itself starts that way.
    private static func hasPreamble(_ text: String, selection: String) -> Bool {
        let pattern =
            #"^(?:(?:sure|certainly|of course|okay|ok|absolutely|got it)\b[,!.:]?\s*|here(?:'s|’s| is| are)\b|below is\b|the (?:edited|revised|rewritten|updated|shortened) (?:text|version)\b|i(?:'ve|’ve| have) (?:edited|rewritten|revised|shortened|updated|changed))"#
        guard text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil else { return false }
        return selection.range(of: pattern, options: [.regularExpression, .caseInsensitive]) == nil
    }

    private static func hasDisallowedControl(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.generalCategory == .control && $0 != "\n" && $0 != "\t" }
    }

    private static func echoes(instruction: String, in output: String, selection: String) -> Bool {
        let wanted = squashed(instruction)
        guard !wanted.isEmpty else { return false }
        let got = squashed(output)
        if got == wanted { return true }
        // A short instruction can sit inside a legitimate edit, so only a longer one counts as an echo inside the text.
        guard wanted.count >= 12, !squashed(selection).contains(wanted) else { return false }
        return got.contains(wanted)
    }

    private static func squashed(_ text: String) -> String {
        text.lowercased().split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ".!?\"'“”"))
    }

    /// True when the instruction plainly asks for less text and doesn't negate it.
    static func asksToShorten(_ instruction: String) -> Bool {
        let lower = instruction.lowercased()
        let negation = #"\b(?:not|never|without|don't|dont|do not|don’t)\b"#
        if lower.range(of: negation, options: .regularExpression) != nil { return false }
        let verbs =
            #"\b(?:shorten|shorter|condense|concise|trim|tighten|abbreviate|cut (?:it |this |that )?down|cut it back|briefer|summari[sz]e)\b"#
        return lower.range(of: verbs, options: .regularExpression) != nil
    }
}
