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
    /// The most UTF-16 units a replacement may have. The editor refuses to write more, so the guard refuses first.
    public static let maximumReplacementUnits = 16_000

    /// Characters allowed for the output: four times the selection, or 500 more than it, whichever is larger, and never
    /// more than `maximumReplacementUnits`.
    public static func maximumLength(forSelectionLength length: Int) -> Int {
        min(max(4 * length, length + 500), maximumReplacementUnits)
    }

    public static func judge(selection: String, instruction: String, output: String) -> VoiceEditVerdict {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .refused(.emptyOutput) }
        if declines(trimmed, selection: selection) { return .refused(.modelDeclined) }
        if hasPreamble(trimmed, selection: selection) { return .refused(.chatter) }
        if hasDisallowedControl(output) { return .refused(.controlCharacters) }
        if trimmed.contains(VoiceEditPrompt.delimiterPrefix), !selection.contains(VoiceEditPrompt.delimiterPrefix) {
            return .refused(.echoesPromptFraming)
        }
        if echoes(instruction: instruction, in: trimmed, selection: selection) { return .refused(.echoesInstruction) }
        if output.count > maximumLength(forSelectionLength: selection.count) || trimmed.utf16.count > maximumReplacementUnits {
            return .refused(.tooLong)
        }
        let source = selection.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed == source { return .refused(.unchanged) }
        if asksToShorten(instruction), trimmed.count >= source.count { return .refused(.notShorter) }
        return .accepted(trimmed)
    }

    /// Opening phrases of a refusal or apology, grouped by what they say. A faithful edit of a selection that opens one way
    /// opens in the same group.
    private static let declineFamilies: [[String]] = [
        ["i'm sorry", "i am sorry", "sorry,"],
        ["i can't", "i cannot", "i can not", "i'm unable", "i am unable", "i won't", "i'm not able"],
        ["as an ai"],
        ["unfortunately", "sadly", "regrettably"],
    ]

    /// Phrases only a model refusing the request says, wherever they fall in the output.
    private static let refusalMarkers =
        #"as an ai|language model|(?:can't|cannot|can not|unable to|won't) (?:help|assist|comply|fulfill|do that|do this)|help with that|assist with that"#

    /// The opening group of `text`, with typographic apostrophes straightened.
    private static func declineFamily(of text: String) -> Int? {
        let lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
        return declineFamilies.firstIndex { $0.contains { lower.hasPrefix($0) } }
    }

    /// An output that opens with an apology or refusal is a decline, unless the selection opens the same way and the output
    /// carries no refusal marker the selection lacks, which makes it a faithful edit of that selection.
    private static func declines(_ text: String, selection: String) -> Bool {
        if text.contains(VoiceEditPrompt.unsupportedSentinel) { return true }
        guard let family = declineFamily(of: text) else { return false }
        guard declineFamily(of: selection) == family else { return true }
        let normalized = { (value: String) in value.lowercased().replacingOccurrences(of: "\u{2019}", with: "'") }
        let markers = try? NSRegularExpression(pattern: refusalMarkers)
        let outputText = normalized(text)
        let sourceText = normalized(selection)
        let found = markers?.matches(in: outputText, range: NSRange(outputText.startIndex..., in: outputText)) ?? []
        return found.contains { match in
            guard let range = Range(match.range, in: outputText) else { return true }
            return !sourceText.contains(outputText[range])
        }
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
