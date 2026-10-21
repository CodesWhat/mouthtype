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

    /// The model's text with "3:15pm" written back as "3:15 PM" when the input spelled its times that way. The native
    /// model lowercases and closes the gap; the deterministic pass already wrote the conventional form, and the guard
    /// would otherwise throw out a correct output over the casing of its AM or PM.
    public static func restoringMeridiem(input: String, output: String) -> String {
        guard input.range(of: #"(?<![\p{L}])[AP]M(?![\p{L}])"#, options: .regularExpression) != nil,
              let expression = try? NSRegularExpression(pattern: #"(?<=\d)[ \t]?([apAP])[mM](?![\p{L}\p{N}])"#) else { return output }
        let source = output as NSString
        var result = output
        for match in expression.matches(in: output, range: NSRange(location: 0, length: source.length)).reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            result.replaceSubrange(range, with: " " + source.substring(with: match.range(at: 1)).uppercased() + "M")
        }
        return result
    }

    private static func terminalMark(_ text: String) -> Character? {
        guard let last = text.last(where: { !$0.isWhitespace }), ".?!".contains(last) else { return nil }
        return last
    }

    static func copiesSurroundingText(input: String, output: String, references: [String]) -> Bool {
        guard !references.isEmpty else { return false }
        func phrase(_ words: [String]) -> String { " " + words.joined(separator: " ") + " " }
        let inputWords = TextMetrics.normalizedWords(input)
        let inputPhrase = phrase(inputWords)
        let outputWords = TextMetrics.normalizedWords(output)
        let outputPhrase = phrase(outputWords)
        let additions: [[String]]
        let retainedWords: [String]
        let hasRetainedTake: Bool
        if !inputWords.isEmpty, let take = outputPhrase.range(of: inputPhrase) {
            additions = [TextMetrics.normalizedWords(String(outputPhrase[..<take.lowerBound])),
                TextMetrics.normalizedWords(String(outputPhrase[take.upperBound...]))]
            retainedWords = inputWords
            hasRetainedTake = true
        } else if inputWords.count <= SmartCleanup.maxWords,
                  outputWords.count <= CleanupLimits.maxOutputTokens(for: input),
                  let take = retainedTake(in: outputWords, matching: inputWords) {
            additions = [Array(outputWords[..<take.lowerBound]), Array(outputWords[take.upperBound...])]
            retainedWords = Array(outputWords[take])
            hasRetainedTake = true
        } else {
            additions = [outputWords]
            retainedWords = []
            hasRetainedTake = false
        }
        let retainedPhrase = phrase(retainedWords)
        func occurrences(of reference: String, in text: String) -> Int {
            var count = 0
            var start = text.startIndex
            while let match = text.range(of: reference, range: start..<text.endIndex) {
                count += 1
                start = text.index(before: match.upperBound)
            }
            return count
        }
        let particles: Set<String> = ["de", "del", "da", "di", "do", "dos", "du", "van", "von", "der", "den", "la", "le", "of", "the", "and", "jr", "sr", "junior", "senior"]
        let subjects: Set<String> = ["i", "we", "you", "he", "she", "it", "they"]
        let lines = references.flatMap { $0.split(whereSeparator: \.isNewline) }.flatMap { line -> [(characters: Int, words: [String], isNameLabel: Bool)] in
            let text = line.trimmingCharacters(in: .whitespaces)
            let parts = text.split(whereSeparator: \.isWhitespace).map(Self.stripped).filter { !$0.isEmpty }
            let words = TextMetrics.normalizedWords(text)
            let subject = words.first?.split(separator: "'").first.map(String.init) ?? ""
            let first = parts.first ?? ""
            let isSubject = subjects.contains(subject) && (first == "I" || first.contains(where: \.isLowercase))
            func labelPart(_ part: String) -> Bool {
                !part.isEmpty && (particles.contains(part.lowercased()) || part.contains(where: \.isUppercase) || part.allSatisfy(\.isNumber))
            }
            let allLabelParts = parts.allSatisfy(labelPart)
            let isNameLabel = !isSubject && allLabelParts && parts.contains { $0.contains(where: \.isUppercase) }
            var result = [(characters: text.count, words: words, isNameLabel: isNameLabel)]
            // Names embedded in a sentence keep the same protection as a standalone label.
            // A fully title-cased subject sentence remains eligible for ordinary corrections.
            if !allLabelParts {
                var group: [String] = []
                for part in parts + [""] {
                    if labelPart(part) {
                        group.append(part)
                    } else {
                        while group.first.map({ !$0.contains(where: \.isUppercase) }) == true { group.removeFirst() }
                        while group.last.map({ !$0.contains(where: \.isUppercase) }) == true { group.removeLast() }
                        if group.filter({ $0.contains(where: \.isUppercase) }).count >= 2 {
                            let name = group.joined(separator: " ")
                            result.append((characters: name.count, words: TextMetrics.normalizedWords(name), isNameLabel: true))
                        }
                        group.removeAll(keepingCapacity: true)
                    }
                }
            }
            return result
        }
        for line in lines where line.characters >= 8 && !line.words.isEmpty {
            let reference = phrase(line.words)
            // Only a complete corrected take may match a reference line. A shorter name/label
            // inside it keeps the existing full-line protection against unspoken replacements.
            let allowed = !line.isNameLabel && retainedPhrase == reference ? 1 : 0
            if !inputPhrase.contains(reference),
               occurrences(of: reference, in: outputPhrase) > allowed { return true }
        }

        guard hasRetainedTake else { return false }
        func windows(_ words: [String]) -> Set<String> {
            guard words.count >= 4 else { return [] }
            return Set((0...(words.count - 4)).map { words[$0..<($0 + 4)].joined(separator: " ") })
        }
        let referenceWindows = lines.reduce(into: Set<String>()) {
            $0.formUnion(windows($1.words))
        }.subtracting(windows(inputWords))
        if additions.contains(where: { !windows($0).isDisjoint(with: referenceWindows) }) { return true }
        // A copied sentence can be a closer match than the corrected take. Two separate plausible
        // takes plus a new context phrase in the chosen span still indicate copying.
        return outputWords.count >= inputWords.count + 4
            && inputWords.count <= SmartCleanup.maxWords
            && outputWords.count <= CleanupLimits.maxOutputTokens(for: input)
            && !windows(retainedWords).isDisjoint(with: referenceWindows)
            && additions.contains { retainedTake(in: $0, matching: inputWords) != nil }
    }

    // Substring edit distance: output before and after the retained take is free. Two rows bound
    // memory; the caller bounds both word counts. Ties retain more text to avoid calling grammar additions copies.
    private static func retainedTake(in output: [String], matching input: [String]) -> Range<Int>? {
        guard !input.isEmpty, !output.isEmpty else { return nil }
        typealias Step = (edits: Int, start: Int)
        func better(_ a: Step, _ b: Step) -> Step {
            if a.edits != b.edits { return a.edits < b.edits ? a : b }
            return a.start <= b.start ? a : b
        }
        var previous: [Step] = (0...output.count).map { (0, $0) }
        var current = previous
        for (index, word) in input.enumerated() {
            current[0] = (index + 1, 0)
            for end in 1...output.count {
                let substitution = (previous[end - 1].edits + (word == output[end - 1] ? 0 : 1), previous[end - 1].start)
                let deletion = (previous[end].edits + 1, previous[end].start)
                let insertion = (current[end - 1].edits + 1, current[end - 1].start)
                current[end] = better(substitution, better(deletion, insertion))
            }
            swap(&previous, &current)
        }
        var best: (edits: Int, range: Range<Int>)?
        // A span must need at most one edit per two input words to count as the retained take.
        for end in 1...output.count where previous[end].edits <= input.count / 2 && previous[end].start < end {
            let candidate = (edits: previous[end].edits, range: previous[end].start..<end)
            if let existing = best,
               existing.edits < candidate.edits || (existing.edits == candidate.edits && existing.range.count >= candidate.range.count) {
                continue
            }
            best = candidate
        }
        return best?.range
    }

    /// A reason to reject, or nil when the output is fine.
    public static func rejection(
        input: String, output: String, level: CleanupLevel, dictionary: [DictionaryRule] = [], snippets: [Snippet] = [],
        nearbySpellings: [String] = [], resolvedInput: String? = nil
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
        if let scale = droppedScale(input: comparableInput, output: comparableOutput) { return "scale word \(scale) missing or changed" }
        for source in [input, resolvedInput].compactMap({ $0 }) {
            if let added = DictionaryReplacer.introducedAlias(input: source, output: trimmed, rules: dictionary) {
                return "dictionary spelling \"\(added)\" added without an exact match"
            }
        }
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

        if let added = insertedNearbyName(input: comparableInput, output: comparableOutput, names: nearbyNames) {
            return "nearby spelling \"\(added)\" added"
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
        if !meridiemPairs(output).isSubset(of: meridiemPairs(input).union(spokenMeridiemPairs(in: input))) {
            return "time of day added or changed"
        }
        let questions = ["what", "what's", "who", "who's", "where", "where's", "when", "why", "how", "which"]
        if let first = TextMetrics.normalizedWords(input).first, questions.contains(first),
           let next = TextMetrics.normalizedWords(output).first, !questions.contains(next) {
            return "question changed into a statement"
        }
        return nil
    }

    /// Each clock time that carries its own AM or PM, as "9:00a" or "5:30p", so a meridiem can't move to another time.
    /// A time spoken in words ("three p m") has no digits to pair with; it is listed by `spokenMeridiemPairs`.
    static func meridiemPairs(_ text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(
            pattern: #"(?i)(?<![\p{L}\p{N}:])(\d{1,2})(?::(\d{2}))?[ \t]*([ap])[. \t]*m\b"#) else { return [] }
        let source = text as NSString
        return Set(expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            let minutes = match.range(at: 2).location == NSNotFound ? "00" : source.substring(with: match.range(at: 2))
            return "\(Int(source.substring(with: match.range(at: 1))) ?? 0):\(minutes)\(source.substring(with: match.range(at: 3)).lowercased())"
        })
    }

    /// Times spoken in words ("nine a m", "three thirty p m", "three oh five p m"), as the same "H:MMl" pairs. The hour
    /// and minutes come from the number words right before the AM or PM, so the letter belongs to that time only.
    private static func spokenMeridiemPairs(in text: String) -> Set<String> {
        guard let expression = try? NSRegularExpression(pattern: #"(?i)(?<!\p{L})([ap])[. \t]*m\b"#) else { return [] }
        let source = text as NSString
        var found = Set<String>()
        for match in expression.matches(in: text, range: NSRange(location: 0, length: source.length)) {
            let before = source.substring(to: match.range.location).split(whereSeparator: \.isWhitespace)
                .suffix(3).map { stripped($0).lowercased() }
            func value(_ back: Int) -> Int? { back <= before.count ? numberWords[before[before.count - back]] : nil }
            func isHour(_ number: Int?) -> Bool { number.map { (1...12).contains($0) } ?? false }
            var hour: Int?
            var minutes = 0
            if before.count >= 3, before[before.count - 2] == "oh", let digit = value(1), (1...9).contains(digit), isHour(value(3)) {
                hour = value(3); minutes = digit
            } else if let ones = value(1), (1...9).contains(ones), let tens = value(2), tens >= 20, isHour(value(3)) {
                hour = value(3); minutes = tens + ones
            } else if let minute = value(1), minute >= 10, isHour(value(2)) {
                hour = value(2); minutes = minute
            } else if isHour(value(1)) {
                hour = value(1)
            }
            guard let hour else { continue }
            found.insert("\(hour):\(String(format: "%02d", minutes))\(source.substring(with: match.range(at: 1)).lowercased())")
        }
        return found
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
        // "at nine oh five" and "nine oh five p m" are the clock time 9:05. Without a time cue "nine oh five" stays the
        // digit string 905, and the colon form never compares equal to the form without one.
        let hours = "(?:one|two|three|four|five|six|seven|eight|nine|ten|eleven|twelve)"
        func clockTime(_ match: NSTextCheckingResult, _ source: NSString, hour: Int, digit: Int) -> String? {
            guard let hourDigits = numberWords[source.substring(with: match.range(at: hour)).lowercased()],
                  let minuteDigit = digits[source.substring(with: match.range(at: digit)).lowercased()] else { return nil }
            return "\(hourDigits):0\(minuteDigit)"
        }
        let notBeforeDigit = "(?!\\s+\(digitPattern))"
        result = replace(result, pattern: "(?i)\\b(at)\\s+(\(hours))\\s+oh\\s+(\(digitPattern))\\b\(notBeforeDigit)") { match, source in
            guard let time = clockTime(match, source, hour: 2, digit: 3) else { return source.substring(with: match.range) }
            return source.substring(with: match.range(at: 1)) + " " + time
        }
        result = replace(result, pattern: "(?i)\\b(\(hours))\\s+oh\\s+(\(digitPattern))(?=\\s+[ap][. \\t]*m\\b)") { match, source in
            clockTime(match, source, hour: 1, digit: 2) ?? source.substring(with: match.range)
        }
        // Only the standard "A/B test" pair stands for the spoken letters "A B"; initials are left alone.
        result = replace(result, pattern: #"(?<![\p{L}\p{N}/])A/B(?=[ \t]+tests?\b|[ \t]+testing\b)"#) { _, _ in "AB" }
        // Spoken digit strings such as a phone number, with the speaker's pauses (commas) between groups.
        result = replace(result, pattern: "(?i)\\b\(digitPattern)(?:,?\\s+\(digitPattern))+\\b") { match, source in
            let words = source.substring(with: match.range).lowercased().split(whereSeparator: { $0.isWhitespace || $0 == "," }).map(String.init)
            guard words.contains("oh") || words.contains("zero") else { return source.substring(with: match.range) }
            return words.compactMap { digits[$0] }.joined()
        }
        // Written phone numbers: the hyphens are formatting.
        result = replace(result, pattern: #"(?<![\p{L}\p{N}-])(\d{3})-(\d{3})-(\d{4})(?![\p{L}\p{N}-])"#) { match, source in
            (1...3).map { source.substring(with: match.range(at: $0)) }.joined()
        }
        result = replace(result, pattern: #"(?<![\p{L}\p{N}-])(\d{3})-(\d{4})(?![\p{L}\p{N}-])"#) { match, source in
            source.substring(with: match.range(at: 1)) + source.substring(with: match.range(at: 2))
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

    static let scaleWords: [String: Int] = ["hundred": 100, "thousand": 1_000, "million": 1_000_000, "billion": 1_000_000_000]

    private static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october", "november", "december",
    ]

    private static func ordinalSuffix(_ value: Int) -> String {
        if (11...13).contains(value % 100) { return "th" }
        switch value % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }

    /// Spoken numbers that read as one value. Every word keeps its own spelling and digits, and the phrase adds one
    /// more accepted spelling, so a wrong value for the phrase still fails.
    /// - "twenty four" also accepts 24, so "twenty four seven" can be "24/7".
    /// - "twenty second" also accepts only "22nd", so "22-second" and "22" fail.
    /// - "fifteen hundred" also accepts 1500. Scale words are checked separately by `droppedScale`.
    /// - "twenty twenty six" also accepts 2026, but only next to a date cue: a month name before it, or "in", "since",
    ///   "by", "year" or "back in" right before it with the phrase ending its clause.
    private static func addPhraseValues(to found: inout [Quantity], tokens: [Substring]) {
        let words = tokens.map { stripped($0).lowercased() }
        func breaks(_ index: Int) -> Bool { tokens[index].last.map { !$0.isLetter && !$0.isNumber } ?? true }
        func cardinalOnes(_ word: String) -> Int? {
            guard let value = numberWords[word], (1...9).contains(value) else { return nil }
            return value
        }
        func ordinalOnes(_ word: String) -> Int? {
            guard let value = ordinalWords[word], (1...9).contains(value) else { return nil }
            return value
        }
        func isTens(_ word: String) -> Bool { (numberWords[word] ?? 0) >= 20 }
        func accept(_ spelling: String, positions: Range<Int>) {
            for index in found.indices where positions.contains(found[index].position) {
                found[index].accepted.insert(spelling)
            }
        }
        func hasYearCue(start: Int, end: Int) -> Bool {
            // "may" is a month only when written "May" in the middle of a sentence, never the verb.
            func isMonth(_ index: Int) -> Bool {
                guard months.contains(words[index]) else { return false }
                guard words[index] == "may" else { return true }
                return tokens[index].first?.isUppercase == true && index > 0
                    && !(tokens[index - 1].last.map { ".!?".contains($0) } ?? true)
            }
            if (max(0, start - 3)..<start).contains(where: isMonth) { return true }
            guard start > 0, ["in", "since", "by", "year"].contains(words[start - 1]) else { return false }
            return breaks(end) || end == words.count - 1
        }
        var index = 0
        while index < words.count {
            guard let first = numberWords[words[index]] else { index += 1; continue }
            // A spoken year: "twenty twenty six", "nineteen eighty four", "twenty oh five".
            if first == 19 || first == 20, !breaks(index), index + 1 < words.count {
                var year: Int?
                var length = 0
                let next = words[index + 1]
                if next == "oh", index + 2 < words.count, let digit = cardinalOnes(words[index + 2]) {
                    year = first * 100 + digit
                    length = 3
                } else if let second = numberWords[next], (10...99).contains(second) {
                    year = first * 100 + second
                    length = 2
                    if isTens(next), !breaks(index + 1), index + 2 < words.count, let digit = cardinalOnes(words[index + 2]) {
                        year = first * 100 + second + digit
                        length = 3
                    }
                }
                if let year, hasYearCue(start: index, end: index + length - 1) {
                    accept(String(year), positions: index..<(index + length))
                    index += length
                    continue
                }
            }
            var value = first
            var length = 1
            if isTens(words[index]), !breaks(index), index + 1 < words.count {
                if let digit = cardinalOnes(words[index + 1]) {
                    value += digit
                    length = 2
                } else if let digit = ordinalOnes(words[index + 1]) {
                    accept(String(value + digit) + ordinalSuffix(value + digit), positions: index..<(index + 2))
                    index += 2
                    continue
                }
            }
            if length > 1 { accept(String(value), positions: index..<(index + length)) }
            index += length
        }
        for phrase in scalePhrases(in: tokens.joined(separator: " ")) {
            accept(String(phrase.value), positions: phrase.positions)
        }
    }

    /// The scale phrases a text states ("fifteen hundred", "five hundred thousand"): each one's value, its scale words and
    /// the word positions it covers.
    private static func scalePhrases(in text: String) -> [(value: Int, scales: [String], positions: Range<Int>)] {
        var phrases: [(value: Int, scales: [String], positions: Range<Int>)] = []
        var total = 0
        var current = 0
        var scales: [String] = []
        var start: Int?
        var last = 0
        func finish() {
            if let start, !scales.isEmpty { phrases.append((total + current, scales, start..<(last + 1))) }
            total = 0; current = 0; scales = []; start = nil
        }
        let allTokens = text.split(whereSeparator: \.isWhitespace)
        for (position, token) in allTokens.enumerated() {
            let word = stripped(token).lowercased()
            let digits = word.replacingOccurrences(of: ",", with: "")
            if let scale = scaleWords[word] {
                scales.append(word)
                if scale == 100 {
                    current = max(current, 1) * 100
                } else {
                    total += max(current, 1) * scale
                    current = 0
                }
            } else if let number = numberWords[word] ?? Int(digits) {
                current += number
            } else if word == "and", start != nil {
                // "five hundred and twelve" is one number; "five hundred and two thousand" is two.
                func number(_ offset: Int) -> Int? {
                    position + offset < allTokens.count ? numberWords[stripped(allTokens[position + offset]).lowercased()] : nil
                }
                func scale(_ offset: Int) -> Bool {
                    position + offset < allTokens.count && scaleWords[stripped(allTokens[position + offset]).lowercased()] != nil
                }
                if number(1) != nil, scale(2) || ((number(1) ?? 0) >= 20 && number(2) != nil && scale(3)) { finish() }
                continue
            } else {
                finish()
                continue
            }
            if start == nil { start = position }
            last = position
            if token.last.map({ !$0.isLetter && !$0.isNumber }) ?? false { finish() }
        }
        finish()
        return phrases
    }

    /// A scale word ("hundred", "thousand", "million", "billion") the output neither keeps nor folds into the value
    /// of the number it scales, such as "five hundred thousand dollars" written "$500".
    static func droppedScale(input: String, output: String) -> String? {
        var words: [String: Int] = [:]
        for token in output.split(whereSeparator: \.isWhitespace) { words[stripped(token).lowercased(), default: 0] += 1 }
        var values: [Int: Int] = [:]
        for value in wordsAndDigits(in: output).flatMap({ $0.accepted }).compactMap({ Int($0) }) { values[value, default: 0] += 1 }
        // Each scale phrase in the input needs its own written value or its own scale words in the output. One
        // "thousand" elsewhere in the text can't stand in for a second dropped one.
        for phrase in scalePhrases(in: input) {
            if let count = values[phrase.value], count > 0 {
                values[phrase.value] = count - 1
            } else if phrase.scales.allSatisfy({ (words[$0] ?? 0) > 0 }) {
                for scale in phrase.scales { words[scale, default: 0] -= 1 }
            } else {
                return phrase.scales.first { (words[$0] ?? 0) <= 0 }
            }
        }
        return nil
    }

    /// Digit groups ("1,000" is 1000, "3:30" is 3 and 30) and small spoken numbers, each with its word position.
    /// A spoken number is kept if the output spells it the same way or as digits.
    static func quantities(in text: String) -> [Quantity] {
        var found = wordsAndDigits(in: text)
        addPhraseValues(to: &found, tokens: text.split(whereSeparator: \.isWhitespace))
        return found
    }

    private static func wordsAndDigits(in text: String) -> [Quantity] {
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
        // The output's own phrase values are left out, or "500 thousand" would vouch for "five hundred thousand".
        for quantity in wordsAndDigits(in: output) { spellings.formUnion(quantity.accepted) }
        spellings.formUnion(output.split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() })
        let tokens = input.split(whereSeparator: \.isWhitespace).map(String.init)
        for quantity in quantities(in: input) where quantity.accepted.isDisjoint(with: spellings) {
            if !laterCue(tokens: tokens, position: quantity.position) { return quantity.label }
        }
        return nil
    }

    // MARK: Names and spellings

    // Reject nearby names that every minimum-edit alignment has to insert, while allowing
    // one-for-one spelling corrections. Two rows bound memory; word limits bound the work.
    private static func insertedNearbyName(input: String, output: String, names: Set<String>) -> String? {
        guard !names.isEmpty else { return nil }
        let before = input.split(whereSeparator: \.isWhitespace).map(stripped).filter {
            !$0.isEmpty && (!FillerRemover.fillerWords.contains($0.lowercased()) || $0 == $0.uppercased())
        }.map { $0.lowercased() }
        let after = output.split(whereSeparator: \.isWhitespace).map { stripped($0).lowercased() }.filter { !$0.isEmpty }
        guard before.count <= SmartCleanup.maxWords,
              after.count <= CleanupLimits.maxOutputTokens(for: input),
              after.contains(where: names.contains) else { return nil }
        struct Step {
            var edits: Int
            var addedNames: Int
            var firstName: String?

            func inserting(_ word: String, isName: Bool) -> Step {
                Step(edits: edits + 1, addedNames: addedNames + (isName ? 1 : 0),
                    firstName: firstName ?? (isName ? word : nil))
            }
        }
        func better(_ left: Step, _ right: Step) -> Step {
            if left.edits != right.edits { return left.edits < right.edits ? left : right }
            return left.addedNames <= right.addedNames ? left : right
        }
        var previous = [Step(edits: 0, addedNames: 0)]
        for word in after { previous.append(previous.last!.inserting(word, isName: names.contains(word))) }
        var current = previous
        for (index, word) in before.enumerated() {
            current[0] = Step(edits: index + 1, addedNames: 0)
            for end in after.indices {
                var substitution = previous[end]
                substitution.edits += word == after[end] ? 0 : 1
                var deletion = previous[end + 1]
                deletion.edits += 1
                let insertion = current[end].inserting(after[end], isName: names.contains(after[end]))
                current[end + 1] = better(substitution, better(deletion, insertion))
            }
            swap(&previous, &current)
        }
        return previous.last?.firstName
    }

    private static func missingLiteral(input: String, output: String) -> String? {
        guard let expression = try? NSRegularExpression(
            pattern: #"`[^`\r\n]+`|(?<![\p{L}\p{N}])"[^"\r\n]+"(?![\p{L}\p{N}])|(?<![\p{L}\p{N}])“[^”\r\n]+”(?![\p{L}\p{N}])|[^\s`]*[@/\\][^\s`]*|(?<![\p{L}\p{N}_.])\.[\p{L}_][\p{L}\p{N}_.-]*"#
        ) else { return nil }
        let wrappers = Set(".,;:!?()[]{}\"'“”‘’")
        let leadingWrappers = wrappers.subtracting(["."])
        func matches(_ text: String) -> [(String, Range<String.Index>)] {
            expression.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
                guard let range = Range(match.range, in: text) else { return nil }
                let raw = text[range]
                if raw.first == "\"" || raw.first == "“" {
                    return ("\"" + raw.dropFirst().dropLast() + "\"", range)
                }
                let leadingTrimmed = text[range].drop(while: leadingWrappers.contains)
                let value = String(leadingTrimmed.reversed().drop(while: wrappers.contains).reversed())
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
