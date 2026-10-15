import Foundation

/// Decides whether a model's output may replace the deterministic text it was made from. Every check answers one
/// failure seen with small models: output that is empty, runs away, drops the speaker's words, changes a number,
/// loses a name or a dictionary spelling, or answers the dictation instead of transcribing it.
public enum SmartCleanupGuard {
    /// Share of the input's content words the output must keep at either model cleanup level.
    public static func minimumKept(for level: CleanupLevel) -> Double { 0.5 }
    /// Share of the output's content words that may be new, past which it is answering rather than transcribing.
    public static func maximumNovel(for level: CleanupLevel) -> Double { 0.5 }

    /// How far after an abandoned number or name its correction cue may appear.
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

    static func copiesSurroundingText(input: String, output: String, references: [String]) -> Bool {
        func phrase(_ words: [String]) -> String { " " + words.joined(separator: " ") + " " }
        let inputWords = TextMetrics.normalizedWords(input)
        let inputPhrase = phrase(inputWords)
        let outputPhrase = phrase(TextMetrics.normalizedWords(output))
        for line in references.flatMap({ $0.split(whereSeparator: \.isNewline) }) {
            let text = line.trimmingCharacters(in: .whitespaces)
            let words = TextMetrics.normalizedWords(text)
            guard text.count >= 8, !words.isEmpty else { continue }
            let reference = phrase(words)
            if !inputPhrase.contains(reference), outputPhrase.contains(reference) { return true }
        }

        // When the take survives unchanged, inspect only the words added around it. A replacement
        // within the take can legitimately share words with the draft, so it isn't evidence of copying.
        guard !inputWords.isEmpty, let take = outputPhrase.range(of: inputPhrase) else { return false }
        func windows(_ words: [String]) -> Set<String> {
            guard words.count >= 4 else { return [] }
            return Set((0...(words.count - 4)).map { words[$0..<($0 + 4)].joined(separator: " ") })
        }
        let referenceWindows = references.reduce(into: Set<String>()) {
            $0.formUnion(windows(TextMetrics.normalizedWords($1)))
        }.subtracting(windows(inputWords))
        let prefix = TextMetrics.normalizedWords(String(outputPhrase[..<take.lowerBound]))
        let suffix = TextMetrics.normalizedWords(String(outputPhrase[take.upperBound...]))
        return !windows(prefix).isDisjoint(with: referenceWindows) || !windows(suffix).isDisjoint(with: referenceWindows)
    }

    /// A reason to reject, or nil when the output is fine.
    public static func rejection(
        input: String, output: String, level: CleanupLevel, dictionary: [DictionaryRule] = [], snippets: [Snippet] = [],
        nearbySpellings: [String] = []
    ) -> String? {
        let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "empty output" }

        let outputWords = TextMetrics.wordCount(trimmed)
        let limit = CleanupLimits.maxOutputTokens(for: input)
        if outputWords > limit { return "output has \(outputWords) words, over the \(limit) limit" }

        if let reason = changedIntent(input: input, output: trimmed) { return reason }
        if let literal = missingLiteral(input: input, output: trimmed) { return "literal \"\(literal)\" changed" }
        let comparableInput = writtenForm(input)
        let comparableOutput = writtenForm(trimmed)
        let outputSpellings = Set(comparableOutput.split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() })
        for word in comparableInput.split(whereSeparator: \.isWhitespace).map(stripped)
        where word.count > 1 && word.contains(where: \.isLetter) && word.allSatisfy({ $0.isUppercase || $0.isNumber }) {
            if !outputSpellings.contains(word.lowercased()) { return "acronym \(word) missing or changed" }
        }

        if let missing = missingNumber(input: comparableInput, output: comparableOutput) { return "number \(missing) missing or changed" }
        if let missing = missingTerm(input: input, output: trimmed, dictionary: dictionary, snippets: snippets) {
            return "\"\(missing)\" missing"
        }
        if let missing = missingName(input: comparableInput, output: comparableOutput) { return "name \"\(missing)\" missing" }

        let nearbyNames = Set(nearbySpellings.map { $0.lowercased() })
        let inputParts = input.split(whereSeparator: \.isWhitespace).map(String.init)
        let outputParts = Set(trimmed.split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() })
        for (index, part) in inputParts.enumerated() {
            let word = stripped(part).lowercased()
            if nearbyNames.contains(word), !outputParts.contains(word), !laterCue(tokens: inputParts, position: index) {
                return "nearby spelling \"\(word)\" changed"
            }
        }

        let inputWords = contentWords(comparableInput)
        let outputContent = contentWords(comparableOutput)
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

    static func changedIntent(input: String, output: String) -> String? {
        func negatives(_ text: String) -> Int {
            let words = TextMetrics.normalizedWords(text)
            return words.indices.filter { index in
                let word = words[index]
                let next = index + 1 < words.count ? words[index + 1] : ""
                if word == "no", ["wait", "sorry"].contains(next) { return false }
                if word == "never", next == "mind" { return false }
                return ["no", "not", "never", "neither", "nor", "without", "cannot"].contains(word) || word.hasSuffix("n't")
            }.count
        }
        if negatives(input) != negatives(output) { return "negation changed" }
        let certainty: Set<String> = ["probably", "maybe", "perhaps", "might", "must", "should", "could", "would"]
        func words(_ text: String) -> [String] {
            TextMetrics.normalizedWords(text).map { $0.hasSuffix("n't") ? String($0.dropLast(3)) : $0 }
        }
        let inputWords = words(input)
        let outputWords = Set(words(output))
        if !outputWords.intersection(certainty).isSubset(of: Set(inputWords)) { return "certainty changed" }
        for (index, word) in inputWords.enumerated()
        where certainty.contains(word) && !outputWords.contains(word) {
            if !laterCue(tokens: inputWords, position: index) { return "certainty changed" }
        }
        func timeOfDay(_ text: String) -> Set<String> {
            var values = Set<String>()
            let pattern = #"(?i)(?<!\p{L})([ap])[. \t]*m\.?(?!\p{L})"#
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let source = text as NSString
                for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    guard let range = Range(match.range, in: text) else { continue }
                    let previous = text[..<range.lowerBound].split(whereSeparator: \.isWhitespace).last.map(String.init) ?? ""
                    if previous.contains(where: \.isNumber) || NumberWords.isNumberWord(previous.lowercased()) {
                        values.insert(source.substring(with: match.range(at: 1)).lowercased())
                    }
                }
            }
            let words = Set(TextMetrics.normalizedWords(text))
            if !words.isDisjoint(with: ["morning", "midnight"]) { values.insert("a") }
            if !words.isDisjoint(with: ["afternoon", "evening", "tonight", "noon"]) { values.insert("p") }
            return values
        }
        if !timeOfDay(output).isSubset(of: timeOfDay(input)) { return "time of day added or changed" }
        let questions = ["what", "what's", "who", "who's", "where", "where's", "when", "why", "how", "which"]
        if let first = TextMetrics.normalizedWords(input).first, questions.contains(first),
           let next = TextMetrics.normalizedWords(output).first, !questions.contains(next) {
            return "question changed into a statement"
        }
        return nil
    }

    /// Equivalent spoken and written spellings for comparison, never for delivery.
    static func writtenForm(_ text: String) -> String {
        func replace(_ text: String, pattern: String, transform: (NSTextCheckingResult, NSString) -> String) -> String {
            let source = text as NSString
            guard let expression = try? NSRegularExpression(pattern: pattern) else { return text }
            let matches = expression.matches(in: text, range: NSRange(location: 0, length: source.length))
            var result = text
            for match in matches.reversed() {
                guard let range = Range(match.range, in: result) else { continue }
                result.replaceSubrange(range, with: transform(match, source))
            }
            return result
        }
        let digits = ["zero": "0", "oh": "0", "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6", "seven": "7", "eight": "8", "nine": "9"]
        let digitPattern = "(?:zero|oh|one|two|three|four|five|six|seven|eight|nine)"
        var result = replace(text, pattern: "(?<![\\p{L}\\p{N}])(?:[A-Z][ \\t.-]+){1,}[A-Z](?![\\p{L}\\p{N}])") { match, source in
            source.substring(with: match.range).filter(\.isLetter)
        }
        result = replace(result, pattern: "\\b([A-Z]{2,})-([A-Z])\\b") { match, source in
            source.substring(with: match.range(at: 1)) + source.substring(with: match.range(at: 2))
        }
        result = replace(result, pattern: #"\bUSB[ \t]+([ABC])\b"#) { match, source in
            "USB" + source.substring(with: match.range(at: 1))
        }
        result = replace(result, pattern: "(?i)\\b\(digitPattern)(?:\\s+\(digitPattern))+\\b") { match, source in
            let words = source.substring(with: match.range).lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
            guard words.contains("oh") || words.contains("zero") else { return source.substring(with: match.range) }
            return words.compactMap { digits[$0] }.joined()
        }
        for _ in 0..<4 {
            result = replace(result, pattern: "(?i)\\b(\\d+(?:\\.\\d+)*)\\s+point\\s+(\(digitPattern)|\\d+)\\b") { match, source in
                let value = source.substring(with: match.range(at: 2)).lowercased()
                return source.substring(with: match.range(at: 1)) + "." + (digits[value] ?? value)
            }
        }
        result = replace(result, pattern: "\\b([A-Z]{2,})\\s+(\(digitPattern))\\b") { match, source in
            source.substring(with: match.range(at: 1)) + (digits[source.substring(with: match.range(at: 2))] ?? "")
        }
        return replace(result, pattern: "\\b(\(digitPattern))\\s+([A-Z]{1,3})\\b") { match, source in
            (digits[source.substring(with: match.range(at: 1))] ?? "") + source.substring(with: match.range(at: 2))
        }
    }

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
                } else if joins, character == "." {
                    digits.append(character)
                } else if !joins {
                    let value = digits.trimmingCharacters(in: CharacterSet(charactersIn: "."))
                    if !value.isEmpty { found.append(Quantity(accepted: [value], position: position, label: value)) }
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
            if !laterCue(tokens: tokens, position: quantity.position) { return quantity.label }
        }
        return nil
    }

    // MARK: Names and spellings

    private static func missingLiteral(input: String, output: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: #"`[^`\r\n]+`|[^\s`]*[@/\\][^\s`]*"#) else { return nil }
        let wrappers = CharacterSet(charactersIn: ".,;:!?()[]{}\"'“”‘’")
        func matches(_ text: String) -> [(String, Range<String.Index>)] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let value = String(text[range]).trimmingCharacters(in: wrappers)
                guard value.contains("`") || value.contains(where: \.isLetter) else { return nil }
                return (value, range)
            }
        }
        let kept = Set(matches(output).map { $0.0 })
        let found = matches(input)
        for (index, item) in found.enumerated() where !kept.contains(item.0) {
            if index + 1 < found.count, kept.contains(found[index + 1].0) {
                let gap = input[item.1.upperBound..<found[index + 1].1.lowerBound]
                    .split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() }.filter { !$0.isEmpty }
                if correctionCues.contains(gap) { continue }
            }
            return item.0
        }
        return nil
    }

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
            let acronymKept = word == word.uppercased() && outputTokens.contains { $0.caseInsensitiveCompare(word) == .orderedSame }
            if outputTokens.contains(word) || acronymKept || laterCue(tokens: tokens, position: index) { continue }
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

    /// Only an abandoned value before a correction cue may disappear; the replacement must survive.
    static func laterCue(tokens: [String], position: Int) -> Bool {
        let lower = tokens.map { stripped($0).lowercased() }
        let range = position...min(lower.count - 1, position + cueReach)
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
