import Foundation

/// Turns a list the speaker counts out loud into a numbered list, without a "numbered list" command.
///
/// A run needs at least two markers that are in order from the first value with no gaps, and the first marker
/// has to start a clause. Marker families, each of which has to be used throughout a run:
/// - cardinals "one, two, three" (to ten) or digits, which always need a comma or colon after them
/// - ordinals "first, second" and "firstly, secondly" (to tenth) and "first of all"; a "lastly", "finally" or
///   "last," closes a run that already has two ordinals and takes the next number
/// - "number one", "step one", "point one", "option one" (digits too), and "option a, option b" (letters need
///   a comma or colon after them)
/// - "(a)", "(b)" and "(1)", "(2)"
///
/// A marker starts a clause at the start of the text, after a newline, or after . ! ? : ; or an ellipsis. Later
/// markers may also follow a comma. Ordinals and parenthesised markers may sit mid-sentence when the run is
/// otherwise in order ("first restart the server second clear the cache"), unless the word before is a
/// determiner, preposition or verb of placing ("came second", "the second"). Every item needs a word, so
/// "one, two, three apples" is counting and stays. Markers followed by "is", "of", "in" and similar without
/// punctuation, or by "time", "quarter" and similar, are prose.
///
/// Each item goes on its own line as `N. Item`, the first word capitalised, a trailing comma or semicolon dropped.
/// The last item ends with its sentence; text after it moves to a new line. Text before the first marker stays
/// as a line above, and a full stop that ends a lead-in announcing a count ("three things.", "the following.")
/// becomes a colon. Lines that already start with `- ` or `N. ` are left alone.
///
/// Misses: a first marker after a comma ("I have three things, first, ..."); a list whose first item is "first
/// of all" spelled any other way; bare letters; and prose that happens to count ("First, thanks. Second, I'm
/// late.") reads as a list.
public struct CountedLists: Sendable {
    /// Edits log under the spoken command stage, like the list commands they sit next to.
    public static let stageName = SpokenCommands.stageName

    public init() {}

    private enum Kind { case clauseStart, comma, soft }

    private struct Candidate {
        var firstWord: Int
        var lastWord: Int
        var start: Int
        /// After the marker and any comma or colon the engine put on it.
        var end: Int
        var family: String
        /// 0 for a closer ("lastly").
        var value: Int
        var kind: Kind

        func lastWordEnd(_ words: [ScanWord]) -> Int { words[lastWord].end }
    }

    private static let cardinals: [String: Int] = [
        "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]
    private static let ordinals: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10,
        "firstly": 1, "secondly": 2, "thirdly": 3, "fourthly": 4, "fifthly": 5, "sixthly": 6, "seventhly": 7,
        "eighthly": 8, "ninthly": 9, "tenthly": 10,
    ]
    private static let closers: Set<String> = ["lastly", "finally", "last"]
    private static let prefixes: Set<String> = ["number", "step", "point", "option"]
    private static let letters: [String: Int] = [
        "a": 1, "b": 2, "c": 3, "d": 4, "e": 5, "f": 6, "g": 7, "h": 8, "i": 9, "j": 10,
    ]
    private static let maxDigit = 12

    /// A mid-sentence ordinal after one of these is ordinary prose ("came second", "the second").
    private static let softBlockers: Set<String> = [
        "the", "a", "an", "in", "on", "at", "of", "my", "his", "her", "our", "their", "your", "its", "this", "that",
        "these", "those", "came", "come", "comes", "was", "is", "are", "were", "be", "been", "to", "for", "with",
        "finished", "finish", "got", "get", "placed", "ranked", "every", "each", "any", "no", "one",
        "than", "by", "from", "as", "into", "onto", "not", "so", "very", "went", "go", "goes", "going",
    ]
    /// Without punctuation, a marker followed by one of these is a sentence ("number one is the price").
    private static let unpunctuatedBlockedFollowers: Set<String> = [
        "is", "was", "are", "were", "am", "be", "been", "has", "had", "have", "of", "in", "on", "at", "by", "as",
        "from", "to", "and", "or", "but", "than", "who", "which", "that", "will", "would", "can", "could", "should",
        "time", "times", "quarter", "half", "round", "place", "floor", "gear", "generation", "language", "person",
        "year", "day", "night", "week", "month", "hand",
    ]

    private static let countWords: Set<String> = [
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "eleven", "twelve",
        "few", "several", "couple", "some", "many", "these", "those", "following",
    ]
    private static let listNouns: Set<String> = [
        "things", "items", "options", "steps", "points", "reasons", "tasks", "ideas", "questions", "priorities",
        "issues", "goals", "problems", "topics", "reminders", "errands", "actions", "changes", "features",
        "rules", "ways", "tips", "thoughts", "parts", "types", "choices", "needs", "requirements",
        "projects", "calls", "emails", "people", "names", "agenda", "ones",
    ]

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return StageResult(text: text) }
        let lower = TextScan.lowered(chars)
        let words = TextScan.words(chars, lower)
        guard words.count >= 2 else { return StageResult(text: text) }

        let candidates = findCandidates(chars, words)
        guard candidates.count >= 2 else { return StageResult(text: text) }
        let runs = buildRuns(candidates, chars, words)
        guard !runs.isEmpty else { return StageResult(text: text) }

        let runStarts = Set(runs.compactMap { $0.first?.start })
        var spans: [TextSpan] = []
        for run in runs { spans += spansFor(run, chars, words, runStarts: runStarts) }
        var result = SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
        // A line break after the last item is layout, not a logged edit.
        result.edits.removeAll { edit in
            (edit.fromText ?? "").allSatisfy(\.isWhitespace) && (edit.toText ?? "").allSatisfy(\.isWhitespace)
        }
        return result
    }

    // MARK: Finding markers

    private func findCandidates(_ chars: [Character], _ words: [ScanWord]) -> [Candidate] {
        var found: [Candidate] = []
        var w = 0
        while w < words.count {
            if let c = candidate(at: w, chars, words) {
                found.append(c)
                w = c.lastWord + 1
            } else {
                w += 1
            }
        }
        return found
    }

    private func gapIsSpaces(_ chars: [Character], _ words: [ScanWord], _ a: Int, _ b: Int) -> Bool {
        b < words.count && words[a].end < words[b].start && TextScan.onlySpaces(chars, words[a].end, words[b].start)
    }

    private func candidate(at w: Int, _ chars: [Character], _ words: [ScanWord]) -> Candidate? {
        let word = words[w]
        let lw = word.lower
        let n = chars.count

        var family: String?
        var value = 0
        var start = word.start
        var lastWord = w
        var endChar = word.end
        var needsPunctuation = false
        var isCloser = false

        if word.start > 0, chars[word.start - 1] == "(", word.end < n, chars[word.end] == ")" {
            // (a) or (1)
            if let v = Self.letters[lw], lw.count == 1 {
                family = "paren/letter"; value = v
            } else if let v = Int(lw), v >= 1, v <= Self.maxDigit, lw.allSatisfy(\.isASCII) {
                family = "paren/digit"; value = v
            }
            start = word.start - 1
            endChar = word.end + 1
        } else if lw == "first", w + 2 < words.count, words[w + 1].lower == "of", words[w + 2].lower == "all",
                  gapIsSpaces(chars, words, w, w + 1), gapIsSpaces(chars, words, w + 1, w + 2) {
            family = "ordinal"; value = 1; lastWord = w + 2; endChar = words[w + 2].end
        } else if Self.prefixes.contains(lw), w + 1 < words.count, gapIsSpaces(chars, words, w, w + 1) {
            let next = words[w + 1]
            if let v = Self.cardinals[next.lower] ?? Self.digitValue(next.lower) {
                family = "\(lw)/number"; value = v
            } else if lw == "option", next.lower.count == 1, let v = Self.letters[next.lower] {
                family = "option/letter"; value = v; needsPunctuation = true
            }
            lastWord = w + 1
            endChar = next.end
        } else if let v = Self.ordinals[lw] {
            family = "ordinal"; value = v
        } else if Self.closers.contains(lw) {
            family = "ordinal"; value = 0; isCloser = true
            needsPunctuation = lw == "last"
        } else if let v = Self.cardinals[lw] ?? Self.digitValue(lw) {
            family = "cardinal"; value = v; needsPunctuation = true
        }
        guard let family else { return nil }

        // Comma or colon the engine put on the marker, only when it is followed by a space or the end.
        var end = endChar
        var punctuated = false
        if end < n, chars[end] == "," || chars[end] == ":", end + 1 >= n || chars[end + 1].isWhitespace {
            end += 1
            punctuated = true
        }
        let place = position(chars, start)
        // A bare cardinal ("three things, one call the bank, two ...") counts only after a comma; buildRuns
        // also asks for a third marker or a lead-in that announces a count.
        if needsPunctuation, !punctuated, !(family == "cardinal" && place == .comma) { return nil }

        // What follows: a word (or an opening quote or bracket) on the same line.
        var after = end
        while after < n, TextScan.isSpace(chars[after]) { after += 1 }
        guard after < n else { return nil }
        if !punctuated, after == end { return nil }
        let nextChar = chars[after]
        guard TextScan.isWordChar(nextChar) || "\"\u{201C}'(".contains(nextChar) else { return nil }
        if !punctuated, let nextWord = words.first(where: { $0.start >= after }), nextWord.start == after,
           Self.unpunctuatedBlockedFollowers.contains(nextWord.lower) {
            return nil
        }

        // Where the marker sits.
        if isListLine(chars, start) { return nil }
        let kind: Kind
        switch place {
        case .clauseStart:
            kind = .clauseStart
        case .comma:
            kind = .comma
        case .none:
            // Mid-sentence, unpunctuated runs: ordinals and bracketed markers only, never a closer, never value 1.
            guard !isCloser, value >= 2, family == "ordinal" || family.hasPrefix("paren") else { return nil }
            if family == "ordinal" {
                guard w > 0, !Self.softBlockers.contains(words[w - 1].lower) else { return nil }
            }
            kind = .soft
        }
        return Candidate(
            firstWord: w, lastWord: lastWord, start: start, end: end, family: family, value: value, kind: kind
        )
    }

    private static func digitValue(_ s: String) -> Int? {
        guard s.allSatisfy({ $0.isASCII && $0.isNumber }), let v = Int(s), v >= 1, v <= maxDigit else { return nil }
        return v
    }

    private enum Position { case clauseStart, comma, none }

    private func position(_ chars: [Character], _ start: Int) -> Position {
        var j = start - 1
        while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
        if j < 0 || chars[j].isNewline { return .clauseStart }
        // A marker glued to the previous character ("x.two") is not a clause start.
        guard j < start - 1 else { return .none }
        if ".!?;:\u{2026}".contains(chars[j]) { return .clauseStart }
        if chars[j] == "," { return .comma }
        return .none
    }

    /// Lines the list commands already formatted ("- milk", "2. eggs").
    private func isListLine(_ chars: [Character], _ index: Int) -> Bool {
        var s = index
        while s > 0, !chars[s - 1].isNewline { s -= 1 }
        while s < chars.count, TextScan.isSpace(chars[s]) { s += 1 }
        guard s < chars.count else { return false }
        if chars[s] == "-", s + 1 < chars.count, chars[s + 1] == " " { return true }
        var j = s
        while j < chars.count, chars[j].isASCII, chars[j].isNumber { j += 1 }
        return j > s && j + 1 < chars.count && chars[j] == "." && chars[j + 1] == " "
    }

    // MARK: Building runs

    private func buildRuns(_ cands: [Candidate], _ chars: [Character], _ words: [ScanWord]) -> [[Candidate]] {
        var runs: [[Candidate]] = []
        var i = 0
        while i < cands.count {
            let first = cands[i]
            guard first.value == 1, first.kind != .soft else { i += 1; continue }
            var run = [first]
            var lastIndex = i
            var j = i + 1
            while j < cands.count {
                let next = cands[j]
                guard next.family == first.family else { j += 1; continue }
                guard next.start >= run[run.count - 1].end, !newlineInside(chars, run[run.count - 1].end, next.start)
                else { break }
                if next.value == 0 {
                    if run.count >= 2 { run.append(next); lastIndex = j }
                    break
                }
                guard next.value == run.count + 1 else { break }
                run.append(next)
                lastIndex = j
                j += 1
            }
            if run.count >= 2, itemsHaveWords(run, chars), bareCardinalsAreCounted(run, chars, words) {
                runs.append(run)
                i = lastIndex + 1
            } else {
                i += 1
            }
        }
        return runs
    }

    /// Bare cardinals ("one call the bank, two email priya") are weak: "we need one more, two at most" has the
    /// same shape. They need three markers, or a lead-in that announces a count.
    private func bareCardinalsAreCounted(_ run: [Candidate], _ chars: [Character], _ words: [ScanWord]) -> Bool {
        guard run[0].family == "cardinal", run.count < 3 else { return true }
        let bare = run.contains { m in m.end == m.lastWordEnd(words) }
        guard bare else { return true }
        var j = run[0].start - 1
        while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
        guard j >= 0, ",.".contains(chars[j]) else { return false }
        return announcesCount(chars, words, endingAt: j)
    }

    /// A line break inside an item (anything but trailing space before the next marker) ends the run.
    private func newlineInside(_ chars: [Character], _ a: Int, _ b: Int) -> Bool {
        var e = b
        while e > a, chars[e - 1].isWhitespace { e -= 1 }
        var i = a
        while i < e { if chars[i].isNewline { return true }; i += 1 }
        return false
    }

    private func itemsHaveWords(_ run: [Candidate], _ chars: [Character]) -> Bool {
        for (k, m) in run.enumerated() {
            let stop = k + 1 < run.count ? run[k + 1].start : lastItemEnd(chars, m.end)
            guard stop > m.end, chars[m.end..<stop].contains(where: { TextScan.isWordChar($0) }) else { return false }
        }
        return true
    }

    /// Where the last item's sentence ends: after its . ! ? ellipsis, or at a line break, or the end of the text.
    private func lastItemEnd(_ chars: [Character], _ from: Int) -> Int {
        var i = from
        while i < chars.count {
            let c = chars[i]
            if c.isNewline { return i }
            if ".!?\u{2026}".contains(c) {
                var e = i + 1
                while e < chars.count, ".!?\u{2026}".contains(chars[e]) { e += 1 }
                if e >= chars.count || chars[e].isWhitespace { return e }
                i = e
                continue
            }
            i += 1
        }
        return chars.count
    }

    // MARK: Rewriting

    private func spansFor(
        _ run: [Candidate], _ chars: [Character], _ words: [ScanWord], runStarts: Set<Int>
    ) -> [TextSpan] {
        var spans: [TextSpan] = []
        var cursor = 0
        for (k, m) in run.enumerated() {
            var rangeStart = m.start
            var prefix = ""
            var j = m.start - 1
            while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
            if k > 0 {
                if j >= 0, chars[j] == "," || chars[j] == ";" { rangeStart = j }
                prefix = j >= 0 && chars[j].isNewline && rangeStart == m.start ? "" : "\n"
            } else if j >= 0, !chars[j].isNewline {
                if chars[j] == ",", m.kind == .comma {
                    // The comma ended the lead-in; it becomes a colon when the lead-in announces a count.
                    rangeStart = j
                    prefix = announcesCount(chars, words, endingAt: j) ? ":\n" : "\n"
                } else if chars[j] == ".", (j == 0 || chars[j - 1] != "."), announcesCount(chars, words, endingAt: j) {
                    rangeStart = j
                    prefix = ":\n"
                } else {
                    prefix = "\n"
                }
            }

            var cutStart = rangeStart
            while cutStart > cursor, TextScan.isSpace(chars[cutStart - 1]) { cutStart -= 1 }

            var rangeEnd = m.end
            var replacement = prefix + "\(k + 1). "
            var cutEnd = m.end
            // Capitalise the item's first word.
            let nextWord = m.lastWord + 1
            if nextWord < words.count, TextScan.onlySpaces(chars, m.end, words[nextWord].start),
               let up = TextScan.capitalized(chars, words[nextWord]) {
                rangeEnd = words[nextWord].end
                cutEnd = rangeEnd
                replacement += up
            } else {
                while cutEnd < chars.count, TextScan.isSpace(chars[cutEnd]) { cutEnd += 1 }
            }
            spans.append(TextSpan(range: rangeStart..<rangeEnd, cut: cutStart..<cutEnd, replacement: replacement))
            cursor = cutEnd
        }

        // Prose after the last item starts a new line.
        if let last = run.last {
            let end = lastItemEnd(chars, last.end)
            var gapEnd = end
            while gapEnd < chars.count, TextScan.isSpace(chars[gapEnd]) { gapEnd += 1 }
            if gapEnd > end, gapEnd < chars.count, !chars[gapEnd].isNewline, !runStarts.contains(gapEnd) {
                spans.append(TextSpan(range: end..<gapEnd, replacement: "\n"))
            }
        }
        return spans
    }

    /// Whether the sentence ending at the full stop `dot` announces a count ("three things", "the following").
    private func announcesCount(_ chars: [Character], _ words: [ScanWord], endingAt dot: Int) -> Bool {
        var sentenceStart = dot
        while sentenceStart > 0, !".!?\u{2026}".contains(chars[sentenceStart - 1]), !chars[sentenceStart - 1].isNewline {
            sentenceStart -= 1
        }
        let inSentence = words.filter { $0.start >= sentenceStart && $0.end <= dot }
        for (i, w) in inSentence.enumerated() {
            if w.lower == "following" { return true }
            guard Self.countWords.contains(w.lower) || Self.digitValue(w.lower) != nil else { continue }
            for next in inSentence.dropFirst(i + 1).prefix(2) where Self.listNouns.contains(next.lower) { return true }
        }
        return false
    }
}
