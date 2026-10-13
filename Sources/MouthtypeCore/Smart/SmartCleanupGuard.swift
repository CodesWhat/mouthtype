import Foundation

/// Decides whether a model's output may replace the deterministic text it was made from. Every check answers one
/// failure seen with small models: output that is empty, runs away, drops the speaker's words, changes a number,
/// loses a name or a dictionary spelling, or answers the dictation instead of transcribing it.
public enum SmartCleanupGuard {
    /// Share of the input's content words the output must keep. `medium` rewrites more, so it may drop more.
    public static func minimumKept(for level: CleanupLevel) -> Double { level == .medium ? 0.3 : 0.5 }
    /// Share of the output's content words that may be new, past which it is answering rather than transcribing.
    public static func maximumNovel(for level: CleanupLevel) -> Double { level == .medium ? 0.6 : 0.5 }

    /// How many words either side of a number or name a self-correction cue still excuses it.
    static let cueReach = 4

    /// Phrases a speaker uses to replace what they just said. Matched as whole words.
    static let correctionCues: [[String]] = [
        ["actually"], ["no", "wait"], ["wait"], ["i", "mean"], ["scratch", "that"], ["sorry"], ["rather"],
        ["make", "that"], ["never", "mind"], ["correction"],
    ]

    /// The model's text with the input's closing mark put back. A dictation that ended in "." or "?" or "!" keeps it:
    /// the model may not turn a statement into a question or the reverse. An input with no closing mark leaves the
    /// model free to add one.
    public static func restoringTerminal(input: String, output: String) -> String {
        guard let wanted = terminalMark(input) else { return output }
        let body = output.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        guard let last = body.last, last != wanted, ".?!".contains(last) else { return output }
        return String(body.dropLast()) + String(wanted)
    }

    private static func terminalMark(_ text: String) -> Character? {
        guard let last = text.last(where: { !$0.isWhitespace }), ".?!".contains(last) else { return nil }
        return last
    }

    /// A reason to reject, or nil when the output is fine.
    public static func rejection(
        input: String, output: String, level: CleanupLevel, dictionary: [DictionaryRule] = [], snippets: [Snippet] = []
    ) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty output" }

        let outputWords = TextMetrics.wordCount(trimmed)
        let limit = CleanupLimits.maxOutputTokens(for: input)
        if outputWords > limit { return "output has \(outputWords) words, over the \(limit) limit" }

        if let missing = missingNumber(input: input, output: trimmed) { return "number \(missing) missing or changed" }
        if let missing = missingTerm(input: input, output: trimmed, dictionary: dictionary, snippets: snippets) {
            return "\"\(missing)\" missing"
        }
        if let missing = missingName(input: input, output: trimmed) { return "name \"\(missing)\" missing" }

        let inputWords = contentWords(input)
        let outputContent = contentWords(trimmed)
        if !inputWords.isEmpty {
            let kept = Double(inputWords.filter { present($0, in: outputContent) }.count) / Double(inputWords.count)
            if kept < minimumKept(for: level) {
                return "kept \(Int(kept * 100))% of the content words, under \(Int(minimumKept(for: level) * 100))%"
            }
        }
        if !outputContent.isEmpty {
            let novel = Double(outputContent.filter { !present($0, in: inputWords) }.count) / Double(outputContent.count)
            if novel > maximumNovel(for: level) {
                return "\(Int(novel * 100))% of the output's content words are new"
            }
        }
        return nil
    }

    // MARK: Words

    static func contentWords(_ text: String) -> [String] {
        var seen = Set<String>()
        return TextMetrics.normalizedWords(text).filter { word in
            word.count > 2 && !word.contains(where: \.isNumber) && !stopWords.contains(word) && seen.insert(word).inserted
        }
    }

    /// Equal, or sharing a four-letter start ("enjoy", "enjoyed"), so inflections don't count as lost words.
    static func present(_ word: String, in words: [String]) -> Bool {
        words.contains { other in
            other == word || (word.count >= 5 && other.count >= 5 && word.prefix(4) == other.prefix(4))
        }
    }

    // MARK: Numbers

    /// A number the input states: the spellings the output may use for it, and where it sits in the input.
    struct Quantity {
        var accepted: Set<String>
        var position: Int
        var label: String
    }

    static let numberWords: [String: Int] = {
        let ones = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven",
                    "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]
        var words = Dictionary(uniqueKeysWithValues: ones.enumerated().map { ($1, $0) })
        for (index, tens) in ["thirty", "forty", "fifty", "sixty", "seventy", "eighty", "ninety"].enumerated() {
            words[tens] = (index + 3) * 10
        }
        return words
    }()

    static let ordinalWords: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
    ]

    /// Digit groups ("1,000" is 1000, "3:30" is 3 and 30) and small spoken numbers, each with its word position.
    /// A spoken number is kept if the output spells it the same way or as digits.
    static func quantities(in text: String) -> [Quantity] {
        var found: [Quantity] = []
        for (position, token) in text.split(whereSeparator: \.isWhitespace).enumerated() {
            let word = stripped(token).lowercased()
            if let value = numberWords[word] ?? ordinalWords[word] {
                found.append(Quantity(accepted: [word, String(value)], position: position, label: word))
                continue
            }
            var digits = ""
            var previous: Character?
            for character in String(token) + " " {
                let joins = (character == "," || character == ".") && previous?.isNumber == true
                if character.isNumber {
                    digits.append(character)
                } else if !joins {
                    if !digits.isEmpty { found.append(Quantity(accepted: [digits], position: position, label: digits)) }
                    digits = ""
                }
                previous = character
            }
        }
        return found
    }

    static func missingNumber(input: String, output: String) -> String? {
        var spellings = Set<String>()
        for quantity in quantities(in: output) { spellings.formUnion(quantity.accepted) }
        spellings.formUnion(output.split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() })
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        for quantity in quantities(in: input) where quantity.accepted.isDisjoint(with: spellings) {
            if !nearCue(tokens: tokens, position: quantity.position) { return quantity.label }
        }
        return nil
    }

    // MARK: Names and spellings

    static func missingTerm(input: String, output: String, dictionary: [DictionaryRule], snippets: [Snippet]) -> String? {
        let terms = dictionary.map(\.written) + snippets.map(\.expansion)
        return terms.first { !$0.isEmpty && input.contains($0) && !output.contains($0) }
    }

    /// A capitalised word in the middle of a sentence is a name the engine heard; it has to survive.
    static func missingName(input: String, output: String) -> String? {
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let outputTokens = Set(output.split(whereSeparator: \.isWhitespace).map(stripped))
        for (index, token) in tokens.enumerated() where index > 0 {
            let word = stripped(token)
            guard let first = word.first, first.isUppercase, word.count > 1, !isIContraction(word) else { continue }
            let previous = tokens[index - 1]
            if let end = previous.last, ".!?:\n".contains(end) || previous.hasPrefix("-") { continue }
            if outputTokens.contains(word) || nearCue(tokens: tokens, position: index) { continue }
            return word
        }
        return nil
    }

    /// Word with surrounding punctuation and a trailing possessive removed.
    static func stripped(_ token: some StringProtocol) -> String {
        var word = String(token).trimmingCharacters(in: .punctuationCharacters.union(.symbols))
        for suffix in ["'s", "\u{2019}s"] where word.hasSuffix(suffix) { word.removeLast(suffix.count) }
        return word
    }

    static func isIContraction(_ word: String) -> Bool {
        word == "I" || word.hasPrefix("I'") || word.hasPrefix("I\u{2019}")
    }

    /// Whether a correction cue sits within `cueReach` words of `position`.
    static func nearCue(tokens: [String], position: Int) -> Bool {
        let lower = tokens.map { stripped($0).lowercased() }
        let range = max(0, position - cueReach)...min(lower.count - 1, position + cueReach)
        for start in range {
            for cue in correctionCues where start + cue.count <= lower.count && Array(lower[start..<(start + cue.count)]) == cue {
                return true
            }
        }
        return false
    }

    // MARK: Stop words

    static let stopWords = Set<String>([
        "the", "and", "but", "for", "nor", "yet", "are", "was", "were", "been", "being", "have", "has", "had", "does",
        "did", "doing", "will", "would", "shall", "should", "can", "could", "may", "might", "must", "not", "its",
        "his", "her", "hers", "him", "she", "they", "them", "their", "theirs", "you", "your", "yours", "our", "ours",
        "that", "this", "these", "those", "there", "here", "then", "than", "with", "without", "from", "into", "onto",
        "about", "over", "under", "out", "off", "just", "also", "very", "really", "kind", "sort", "like", "know",
        "mean", "okay", "well", "yeah", "yes", "wait", "actually", "sorry", "rather", "basically", "maybe",
        "probably", "literally", "totally", "right", "got", "get", "one", "some", "any", "all", "who", "what",
        "when", "where", "why", "how", "which", "whose", "whom", "let", "lets", "let's", "its", "it's", "i'm", "i've",
        "i'll", "i'd", "you're", "you've", "you'll", "you'd", "we're", "we've", "we'll", "we'd", "they're", "they've",
        "they'll", "they'd", "he's", "she's", "that's", "there's", "here's", "what's", "who's", "how's", "where's",
        "isn't", "aren't", "wasn't", "weren't", "don't", "doesn't", "didn't", "won't", "wouldn't", "can't", "couldn't",
        "shouldn't", "haven't", "hasn't", "hadn't", "cannot", "gonna", "wanna", "gotta", "going", "um", "uh", "umm",
        "hmm", "huh", "err", "ahh", "ugh", "oh", "ooh", "okay", "ok", "hey", "now", "too", "still", "even", "ever",
        "much", "many", "more", "most", "other", "such", "only", "own", "same", "both", "each", "few", "again",
        "because", "while", "though", "although", "since", "until", "unless", "whether", "after", "before", "during",
        "between", "through", "against", "above", "below", "else", "once", "thing", "things", "stuff",
    ]).union(numberWords.keys).union(ordinalWords.keys)
}
