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
enum VoiceEditGuard {
    /// The most UTF-16 units a replacement may have. The editor refuses to write more, so the guard refuses first.
    static let maximumReplacementUnits = 16_000

    /// Characters allowed for the output: four times the selection, or 500 more than it, whichever is larger, and never
    /// more than `maximumReplacementUnits`.
    static func maximumLength(forSelectionLength length: Int) -> Int {
        min(max(4 * length, length + 500), maximumReplacementUnits)
    }

    static func judge(selection: String, instruction: String, output: String) -> VoiceEditVerdict {
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

    /// Ways a model says it can't or won't. Spliced into `refusalMarkers`.
    private static let inability = #"(?:can't|cannot|can not|won't|will not|unable to|not able to)"#

    /// Where a refusal phrase has to stop to count: at punctuation or the end of the text. "I can't help with that this
    /// week." carries on, so it's a sentence and not a refusal. A lookahead keeps the punctuation out of the match.
    private static let phraseEnd = #"(?=\s*[.,!?]|\s*$)"#

    /// An inability phrase anywhere in a sentence.
    private static let inabilityClause: [NSRegularExpression] = [compileMarker(#"\bINABILITY\b"#)].compactMap { $0 }

    /// Phrases only a model refusing the request says, wherever they fall in the output: AI framing, a first-person
    /// refusal to help or comply, the same with the subject dropped at a sentence start, and a first-person refusal to
    /// act on the text or the request, and a flat "that isn't possible". One pattern per marker, so the selection can be
    /// checked for the same marker. No pattern lets `\s*` follow a boundary that matches at every newline: that rescans
    /// a long run of blank lines from each one and goes quadratic.
    private static let refusalMarkers: [NSRegularExpression] = [
        #"\bas an ai\b"#,
        #"\blanguage model\b"#,
        #"\bi(?:'m| am)? INABILITY (?:(?:comply|fulfill|do (?:that|this))\b|(?:help|assist)(?: you)?(?: with (?:that|this|it|(?:your|that|the) request))?END)"#,
        #"(?:^|[.!?,;:]\s*|[\r\n][^\S\r\n]*)INABILITY (?:help|assist)(?: you)?(?: with (?:that|this|it))?END"#,
        #"\bi(?:'m| am)? INABILITY (?:edit|rewrite|rephrase|reword|revise|change|modify|provide|answer|write|generate|create|process|complete) (?:(?:this|that|it)END|(?:the|your|that|this)(?: following)? (?:text|selection|request)\b)"#,
    ].compactMap(compileMarker)

    /// "That isn't possible" and its kin. Unlike `refusalMarkers`, a faithful rewrite can say it ("We can't deliver by
    /// Friday." becomes "Delivery by Friday? That isn't possible."), so it only declines when the rest of the output
    /// keeps little of the selection.
    private static let impossibilityMarker: NSRegularExpression? = compileMarker(
        #"\b(?:that|this|it|(?:your|the|that|this) request) (?:isn't|is not|wasn't|was not) (?:possibleEND|something i can (?:do|help with)\b)"#)

    private static func compileMarker(_ pattern: String) -> NSRegularExpression? {
        try? NSRegularExpression(
            pattern: pattern.replacingOccurrences(of: "INABILITY", with: inability).replacingOccurrences(of: "END", with: phraseEnd))
    }

    /// Opening phrases of an apology, a refusal or a regret, grouped by what they say. A faithful edit of a selection that
    /// opens one way opens in the same group.
    private static let declineFamilies: [[String]] = [
        ["i'm sorry", "i am sorry", "sorry", "i apologize", "i apologise", "my apologies", "apologies"],
        [
            "i can't", "i cannot", "i can not", "i'm unable", "i am unable", "i won't", "i will not", "i'm not able",
            "i am not able",
        ],
        ["unfortunately", "sadly", "regrettably", "i regret", "i'm afraid", "i am afraid"],
    ]

    /// Words too common to show that an output kept the selection's content.
    private static let stopwords: Set<String> = [
        "the", "and", "for", "but", "not", "that", "this", "with", "from", "you", "your", "are", "was", "were", "can",
        "will", "have", "has", "had", "its", "our", "they", "them",
    ]

    /// The share of the selection's content words an opening apology or refusal has to keep to count as an edit of it.
    private static let minimumKeptShare = 0.3

    /// Lowercased and trimmed, with typographic and modifier apostrophes straightened.
    private static func normalized(_ text: String) -> String {
        var lower = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for apostrophe in ["\u{2018}", "\u{2019}", "\u{02BC}", "\u{FF07}"] {
            lower = lower.replacingOccurrences(of: apostrophe, with: "'")
        }
        return lower
    }

    /// The opening group of already normalized `text`.
    private static func declineFamily(of text: String) -> Int? {
        declineFamilies.firstIndex { $0.contains { text.hasPrefix($0) } }
    }

    /// Runs of letters and digits in already normalized `text`.
    private static func words(in text: String) -> Set<String> {
        Set(text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
    }

    /// How many of the selection's content words the output kept. A word counts as kept when the output has it, or when a
    /// word of `stemSource` (the output's words by default) is four or more characters and starts it or is started by it,
    /// or shares its first five characters, so "reply" is kept by "replying" and "cancel" by "canceled". A synonym keeps
    /// nothing.
    private static func keptCount(of content: Set<String>, in output: Set<String>, stemSource: Set<String>? = nil) -> Int {
        let long = (stemSource ?? output).filter { $0.count >= 4 }
        var stems = Set<Substring>()
        for word in long {
            for length in 4...word.count { stems.insert(word.prefix(length)) }
        }
        return content.count { word in
            if output.contains(word) { return true }
            guard word.count >= 4 else { return false }
            if stems.contains(Substring(word)) || (word.count >= 5 && stems.contains(word.prefix(5))) { return true }
            return (4..<word.count).contains { long.contains(String(word.prefix($0))) }
        }
    }

    /// The sentences of already normalized `text`, split at ".", "!", "?" and line breaks.
    private static func sentences(of text: String) -> [String] {
        text.split(whereSeparator: { ".!?\n\r".contains($0) }).map(String.init)
    }

    /// The clauses of already normalized `text`: sentences, further split at commas, semicolons and colons.
    private static func clauses(of text: String) -> [String] {
        text.split(whereSeparator: { ".!?\n\r,;:".contains($0) }).map(String.init)
    }

    private static func matches(_ marker: NSRegularExpression, _ value: String) -> Bool {
        marker.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }

    /// An output is a decline when it carries the unsupported-request sentinel, when it introduces a refusal marker the
    /// selection has no match for, or when it newly opens with an apology, refusal or regret and keeps little of what the
    /// selection said. The opening alone doesn't decide it: "make this more apologetic" yields an edit that opens with an
    /// apology and still says what the selection said.
    private static func declines(_ text: String, selection: String) -> Bool {
        if text.contains(VoiceEditPrompt.unsupportedSentinel) { return true }
        let outputText = normalized(text)
        let sourceText = normalized(selection)
        if refusalMarkers.contains(where: { matches($0, outputText) && !matches($0, sourceText) }) { return true }
        let content = words(in: sourceText).filter { $0.count >= 3 && !stopwords.contains($0) }
        if let impossibility = impossibilityMarker, matches(impossibility, outputText), !matches(impossibility, sourceText) {
            // Judge overlap on the sentences that aren't the impossibility statement itself.
            let rest = words(in: sentences(of: outputText).filter { !matches(impossibility, $0) }.joined(separator: ". "))
            if content.count < 2 || Double(keptCount(of: content, in: rest)) / Double(content.count) < minimumKeptShare {
                return true
            }
        }
        guard let family = declineFamily(of: outputText), declineFamily(of: sourceText) != family else { return false }
        guard content.count >= 2 else { return false }
        // Words inside an inability clause, up to the nearest comma ("I can't process this input.") match the selection's words only exactly. A
        // stem match there is the refusal's own verb, not the selection's content.
        let outside = words(
            in: clauses(of: outputText).filter { clause in
                !inabilityClause.contains { matches($0, clause) }
            }.joined(separator: ". "))
        let kept = keptCount(of: content, in: words(in: outputText), stemSource: outside)
        return Double(kept) / Double(content.count) < minimumKeptShare
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
