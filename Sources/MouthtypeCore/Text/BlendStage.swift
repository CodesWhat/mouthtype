import Foundation

/// What is around the cursor, when the app could read it.
public struct InsertionContext: Sendable, Equatable {
    public var before: String?
    public var after: String?

    public init(before: String? = nil, after: String? = nil) {
        self.before = before
        self.after = after
    }
}

/// Fits the result into its surroundings.
///
/// - `before` ends mid-sentence (last non-space character is a letter, digit, comma or semicolon, and no line
///   break sits between it and the cursor): lowercase the first letter, unless the first word is `I`/`I'm`/...,
///   an all-caps acronym, a mixed-case word (`McDonald`, `iPhone`), or one a dictionary rule or snippet wrote
///   (`protectedWords`).
/// - `after` starts with text, allowing spaces/tabs but not a new line: drop one trailing full stop (not an ellipsis).
/// - Otherwise, at the start of a sentence or with no context, capitalise the first letter (same exceptions).
///
/// Known miss: a proper noun that starts the result mid-sentence ("Sarah said yes") is lowercased, because
/// the engine's capital cannot be told apart from a sentence start.
///
/// Leading and trailing spacing is not this stage's job; the paste layer adds the leading space.
public struct BlendStage: Sendable {
    public static let stageName = "blend"

    private let context: InsertionContext?
    private let protectedWords: Set<String>

    public init(context: InsertionContext?, protectedWords: Set<String> = []) {
        self.context = context
        self.protectedWords = protectedWords
    }

    /// First word of each string, exactly as written, for use as `protectedWords`.
    public static func firstWords(of strings: [String]) -> Set<String> {
        var result = Set<String>()
        for s in strings {
            let chars = Array(s)
            if let w = TextScan.words(chars, TextScan.lowered(chars)).first {
                result.insert(String(chars[w.start..<w.end]))
            }
        }
        return result
    }

    private enum Position { case midSentence, sentenceStart, leave }

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        var spans: [TextSpan] = []

        // Casing of the first word.
        if let f = chars.firstIndex(where: { !$0.isWhitespace }), chars[f].isLetter {
            let word = TextScan.words(chars, TextScan.lowered(chars)).first { $0.start == f }
            if let word {
                let original = String(chars[word.start..<word.end])
                if !protectedWords.contains(original) && !isPronounI(original) {
                    switch position() {
                    case .midSentence:
                        if let low = lowercasedFirst(original) {
                            spans.append(TextSpan(range: word.start..<word.end, replacement: low))
                        }
                    case .sentenceStart:
                        if let up = TextScan.capitalized(chars, word) {
                            spans.append(TextSpan(range: word.start..<word.end, replacement: up))
                        }
                    case .leave:
                        break
                    }
                }
            }
        }

        // A full stop before text that already follows the cursor.
        if let after = context?.after, let first = after.drop(while: { $0 == " " || $0 == "\t" }).first, !first.isWhitespace {
            var e = chars.count
            while e > 0, chars[e - 1].isWhitespace { e -= 1 }
            if e > 0, chars[e - 1] == ".", !(e > 1 && chars[e - 2] == ".") {
                spans.append(TextSpan(range: (e - 1)..<e, replacement: ""))
            }
        }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    private func position() -> Position {
        guard let before = context?.before else { return .sentenceStart }
        guard let lastIdx = before.lastIndex(where: { !$0.isWhitespace }) else { return .sentenceStart }
        if before[lastIdx...].contains(where: { $0.isNewline }) { return .sentenceStart }
        let last = before[lastIdx]
        if last.isLetter || last.isNumber || last == "," || last == ";" { return .midSentence }
        if ".!?:\u{2026}".contains(last) { return .sentenceStart }
        return .leave
    }

    /// `I`, `I'm`, `I'll`, `I've`, `I'd`.
    private func isPronounI(_ word: String) -> Bool {
        guard word.first == "I" else { return false }
        return word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}")
    }

    /// The word with its first letter lowercased, or nil when it should stay (acronym, mixed case, already lower).
    private func lowercasedFirst(_ word: String) -> String? {
        guard let first = word.first, first.isUppercase else { return nil }
        let rest = word.dropFirst()
        if rest.contains(where: { $0.isUppercase }) { return nil }   // acronym or mixed case
        return first.lowercased() + rest
    }
}
