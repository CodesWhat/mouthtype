import Foundation

public enum Capitalisation: String, Sendable, Equatable, CaseIterable {
    /// Capitals as the engine and earlier stages left them.
    case sentence
    /// Sentence starts are lowercased when it is safe to (see `StyleStage`).
    case lowercase
}

public enum EndingPunctuation: String, Sendable, Equatable, CaseIterable {
    case keep
    /// Drop the final full stop of a short dictation.
    case dropFinalFullStop
}

public enum StylePreset: String, Sendable, Equatable, CaseIterable {
    case formal, casual, veryCasual, excited

    public var title: String {
        switch self {
        case .formal: "Formal"
        case .casual: "Casual"
        case .veryCasual: "Very casual"
        case .excited: "Excited"
        }
    }

    public var options: StyleOptions {
        switch self {
        case .formal: StyleOptions(capitalisation: .sentence, endingPunctuation: .keep)
        case .casual: StyleOptions(capitalisation: .sentence, endingPunctuation: .dropFinalFullStop)
        case .veryCasual: StyleOptions(capitalisation: .lowercase, endingPunctuation: .dropFinalFullStop)
        case .excited: StyleOptions(capitalisation: .sentence, endingPunctuation: .keep, excited: true)
        }
    }
}

/// The switches under the presets. A combination that matches no preset is "custom".
public struct StyleOptions: Sendable, Equatable {
    public var capitalisation: Capitalisation
    public var endingPunctuation: EndingPunctuation
    /// The Excited tone: a short message's final full stop becomes an exclamation mark, and the Thorough model is asked to
    /// use exclamation marks where the speaker sounds enthusiastic. It never adds or changes a word.
    public var excited: Bool

    public init(capitalisation: Capitalisation = .sentence, endingPunctuation: EndingPunctuation = .keep, excited: Bool = false) {
        self.capitalisation = capitalisation
        self.endingPunctuation = endingPunctuation
        self.excited = excited
    }

    public static let formal = StylePreset.formal.options

    /// The preset these switches add up to, or nil for a custom mix.
    public var preset: StylePreset? {
        StylePreset.allCases.first { $0.options == self }
    }
}

/// The tone pass: runs after blend and before whitespace, and changes only casing and the final full stop.
///
/// - `endingPunctuation == .dropFinalFullStop`: removes the final `.` when the whole dictation is short (at most
///   two sentences and under 25 words), has no list lines, and does not end in an abbreviation ("etc.", "p.m.").
///   Question and exclamation marks stay.
/// - `excited`: turns that same final `.` into `!` instead of removing it, under the same short-message rules. Ignored when
///   `endingPunctuation` already drops the stop.
/// - `capitalisation == .lowercase`: lowercases a word that starts a sentence (start of the text, a line, a list
///   item, or after `. ! ? …`) only when it is in `CommonWords` or the same word already appears in lowercase
///   elsewhere in the text. Capitalised words in the middle of a sentence are left alone (the engine capitalised
///   them as names), and so are `I` and its contractions, mixed-case and all-caps words, dictionary and snippet
///   output, URLs, emails, code-looking tokens, anything inside straight or curly quotes, and list markers.
///   Misses: a name that is also an everyday word at a sentence start ("Will", "Bill" is not listed but "Will"
///   is) is lowercased, and an unlisted ordinary word at a sentence start ("Congratulations") keeps its capital.
public struct StyleStage: Sendable {
    public static let stageName = BlendStage.stageName

    private let options: StyleOptions
    private let protectedWords: Set<String>

    static let shortMessageWords = 25
    static let shortMessageSentences = 2

    public init(options: StyleOptions, protectedWords: Set<String> = []) {
        self.options = options
        self.protectedWords = protectedWords
    }

    /// Every word in the given strings, exactly as written, for use as `protectedWords`.
    public static func words(of strings: [String]) -> Set<String> {
        var result = Set<String>()
        for s in strings {
            let chars = Array(s)
            for w in TextScan.words(chars, TextScan.lowered(chars)) { result.insert(String(chars[w.start..<w.end])) }
        }
        return result
    }

    public func apply(_ text: String) -> StageResult {
        guard options != .formal else { return StageResult(text: text) }
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        let words = TextScan.words(chars, TextScan.lowered(chars))
        let shielded = shieldedChars(chars)

        var spans: [TextSpan] = []
        if options.capitalisation == .lowercase {
            spans += lowercaseSpans(chars, words, shielded)
        }
        let ending = options.endingPunctuation == .dropFinalFullStop ? "" : options.excited ? "!" : nil
        if let ending, let drop = finalStopSpan(chars, words, spans, replacingWith: ending) {
            spans.removeAll { $0.range.upperBound == drop.range.upperBound - 1 && drop.range.contains($0.range.lowerBound) }
            spans.append(drop)
        }
        var result = SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
        result.edits = result.edits.map { edit in
            var edit = edit
            edit.kind = .replace
            return edit
        }
        return result
    }

    // MARK: Lowercase

    private func lowercaseSpans(_ chars: [Character], _ words: [ScanWord], _ shielded: [Bool]) -> [TextSpan] {
        var lowerForms = Set<String>()
        for w in words {
            let original = String(chars[w.start..<w.end])
            if original == w.lower { lowerForms.insert(original) }
        }
        var spans: [TextSpan] = []
        for w in words where startsSentence(chars, w.start) {
            guard !shielded[w.start] else { continue }
            let first = chars[w.start]
            guard first.isLetter, first.isUppercase else { continue }
            let original = String(chars[w.start..<w.end])
            if original.dropFirst().contains(where: { $0.isUppercase }) { continue }
            if original == "I" || original.hasPrefix("I'") || original.hasPrefix("I\u{2019}") { continue }
            if protectedWords.contains(original) { continue }
            guard CommonWords.set.contains(w.lower) || lowerForms.contains(w.lower) else { continue }
            spans.append(TextSpan(range: w.start..<w.end, replacement: w.lower))
        }
        return spans
    }

    /// Whether a word at `index` begins a sentence, a line or a list item.
    private func startsSentence(_ chars: [Character], _ index: Int) -> Bool {
        var j = index - 1
        while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
        if j < 0 || chars[j].isNewline { return true }
        if chars[j] == "-", j == 0 || chars[j - 1].isNewline { return true }
        guard j < index - 1 else { return false }
        return ".!?\u{2026}".contains(chars[j])
    }

    // MARK: Final full stop

    private static let abbreviations: Set<String> = [
        "etc", "vs", "inc", "ltd", "co", "mr", "mrs", "ms", "dr", "jr", "sr", "st", "approx", "dept",
    ]

    private func finalStopSpan(_ chars: [Character], _ words: [ScanWord], _ existing: [TextSpan], replacingWith mark: String) -> TextSpan? {
        var e = chars.count - 1
        while e >= 0, chars[e].isWhitespace { e -= 1 }
        guard e >= 1, chars[e] == ".", chars[e - 1] != ".", chars[e - 1] != "\u{2026}" else { return nil }
        guard !hasListLine(chars) else { return nil }
        guard TextMetrics.wordCount(String(chars)) < Self.shortMessageWords,
            sentenceCount(chars, upTo: e) <= Self.shortMessageSentences
        else { return nil }

        var tokenStart = e
        while tokenStart > 0, !chars[tokenStart - 1].isWhitespace { tokenStart -= 1 }
        let token = String(chars[tokenStart..<e])
        if token.contains(".") || Self.abbreviations.contains(token.lowercased()) { return nil }

        guard TextScan.isWordChar(chars[e - 1]), let word = words.last(where: { $0.end == e }) else {
            return TextSpan(range: e..<(e + 1), replacement: mark)
        }
        // Reuse a lowercase change to the same word so the two edits do not collide.
        var replacement = String(chars[word.start..<word.end])
        if let lowered = existing.first(where: { $0.range == word.start..<word.end }) { replacement = lowered.replacement }
        return TextSpan(range: word.start..<(e + 1), replacement: replacement + mark)
    }

    private func hasListLine(_ chars: [Character]) -> Bool {
        var i = 0
        while i < chars.count {
            if i == 0 || chars[i - 1].isNewline {
                if chars[i] == "-", i + 1 < chars.count, chars[i + 1] == " " { return true }
                var j = i
                while j < chars.count, chars[j].isNumber { j += 1 }
                if j > i, j + 1 < chars.count, chars[j] == ".", chars[j + 1] == " " { return true }
            }
            i += 1
        }
        return false
    }

    /// Sentence ends up to `limit`, counting a line break as an end and any unfinished tail as one more sentence.
    private func sentenceCount(_ chars: [Character], upTo limit: Int) -> Int {
        var count = 0
        var pending = false
        var i = 0
        while i <= limit {
            let c = chars[i]
            if c.isNewline {
                if pending { count += 1; pending = false }
            } else if ".!?\u{2026}".contains(c), i == limit || chars[i + 1].isWhitespace || ".!?\u{2026}".contains(chars[i + 1]) {
                if pending { count += 1; pending = false }
            } else if !c.isWhitespace {
                pending = true
            }
            i += 1
        }
        return count + (pending ? 1 : 0)
    }

    // MARK: Shielded text

    /// Characters the lowercase pass must not touch: quoted text and URL, email or code-looking tokens.
    private func shieldedChars(_ chars: [Character]) -> [Bool] {
        var shielded = [Bool](repeating: false, count: chars.count)
        var open: Int?
        for (i, c) in chars.enumerated() {
            if c == "\"" {
                if let start = open {
                    for k in start...i { shielded[k] = true }
                    open = nil
                } else {
                    open = i
                }
            }
        }
        var curly: Int?
        for (i, c) in chars.enumerated() {
            if c == "\u{201C}" { curly = i }
            if c == "\u{201D}", let start = curly {
                for k in start...i { shielded[k] = true }
                curly = nil
            }
        }
        var i = 0
        while i < chars.count {
            guard !chars[i].isWhitespace else { i += 1; continue }
            var j = i
            while j < chars.count, !chars[j].isWhitespace { j += 1 }
            if looksLikeCode(chars[i..<j]) { for k in i..<j { shielded[k] = true } }
            i = j
        }
        return shielded
    }

    private func looksLikeCode(_ token: ArraySlice<Character>) -> Bool {
        let t = Array(token)
        let s = String(t)
        if s.contains("://") || s.contains("@") || s.contains("/") || s.contains("\\") || s.contains("_") || s.contains("`") {
            return true
        }
        for k in 1..<max(1, t.count - 1) where t[k] == "." && TextScan.isWordChar(t[k - 1]) && TextScan.isWordChar(t[k + 1]) {
            return true
        }
        return false
    }
}
