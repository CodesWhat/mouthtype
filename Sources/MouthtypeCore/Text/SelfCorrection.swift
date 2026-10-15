import Foundation

/// Resolves the one self-correction shape that is safe to settle without a model: `<value A> [,] <cue> [,] <value B>`
/// where A and B are the same kind of value ("at two, actually three" becomes "at three").
///
/// Cues: actually, no wait, no sorry, sorry, I mean, or rather, rather, make that, scratch that, no, wait.
/// Kinds: number (words or digits), clock time, money, percent, weekday, month, month and day, ordinal.
///
/// A bare "wait" counts only with a comma after it. Conservative on purpose. B must be a bare value of A's kind straight after the cue, optionally after a
/// preposition or determiner that repeats the one before A ("on Monday, I mean on Tuesday" becomes "on Tuesday").
/// Nothing is touched when B is missing or is a clause ("I have two, actually I have none"), when the kinds differ
/// ("twenty dollars, no, thirty"), when anything but spaces and one comma sits between the pieces, or when a
/// sentence boundary does. Names and phrases are left to the model.
///
/// A clock time can also be corrected to a bare hour at the end of a sentence.
/// English only.
public struct SelfCorrection: Sendable {
    public static let stageName = "self-correction"

    public init() {}

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard chars.count >= 5 else { return StageResult(text: text) }
        let scan = Scan(chars: chars)
        return SpanRewriter.apply(scan.spans(), to: chars, stage: Self.stageName)
    }

    // MARK: Vocabulary

    enum Kind { case number, time, money, percent, weekday, month, monthDay, ordinal }

    /// Longest first within a start word is not needed: each cue is tried at its own first word.
    static let cues: [[String]] = [
        ["actually"], ["no", "wait"], ["no", "sorry"], ["sorry"], ["i", "mean"], ["or", "rather"], ["rather"],
        ["make", "that"], ["scratch", "that"], ["no"], ["wait"],
    ]
    /// Cues whose words may have a comma between them ("no, wait").
    static let commaCues: Set<[String]> = [["no", "wait"], ["no", "sorry"]]
    /// A bare "wait" is also an instruction ("step two, wait ten seconds"), so it needs a comma after it.
    static let commaAfterCues: Set<[String]> = [["wait"]]

    static let prepositions: Set<String> = [
        "at", "on", "in", "by", "for", "to", "from", "until", "till", "around", "about", "the", "a", "an",
        "this", "next", "last", "before", "after", "of",
    ]
    static let weekdays: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
    ]
    static let months: Set<String> = [
        "january", "february", "march", "april", "may", "june", "july", "august", "september", "october",
        "november", "december",
    ]
    static let moneyWords: Set<String> = ["dollars", "dollar", "bucks", "euros", "euro"]
    static let ordinalValues: [String: Int] = [
        "first": 1, "second": 2, "third": 3, "fourth": 4, "fifth": 5, "sixth": 6, "seventh": 7, "eighth": 8,
        "ninth": 9, "tenth": 10, "eleventh": 11, "twelfth": 12, "thirteenth": 13, "fourteenth": 14,
        "fifteenth": 15, "sixteenth": 16, "seventeenth": 17, "eighteenth": 18, "nineteenth": 19, "twentieth": 20,
        "thirtieth": 30,
    ]

    // MARK: Tokens

    private struct Token {
        var start: Int
        var end: Int
        var lower: String
    }

    private enum Gap { case space, comma, hyphen, boundary }

    private struct Candidate {
        var kind: Kind
        var end: Int
    }

    private struct Scan {
        let chars: [Character]
        var tokens: [Token] = []

        init(chars: [Character]) {
            self.chars = chars
            tokenize()
        }

        // MARK: Tokenizing

        private static let leadingPunct: Set<Character> = ["(", "\"", "\u{201C}", "\u{2018}", "[", "'"]
        private static let trailingPunct: Set<Character> = [
            ",", ".", ";", ":", "!", "?", "\u{2026}", ")", "\"", "\u{201D}", "\u{2019}", "'", "]",
        ]

        private mutating func tokenize() {
            var i = 0
            let n = chars.count
            while i < n {
                if chars[i].isWhitespace { i += 1; continue }
                var j = i
                while j < n, !chars[j].isWhitespace { j += 1 }
                var s = i, e = j
                while s < e, Self.leadingPunct.contains(chars[s]) { s += 1 }
                while e > s, Self.trailingPunct.contains(chars[e - 1]) { e -= 1 }
                // "p.m." and "a.m." keep their last dot.
                let bare = String(chars[s..<e]).lowercased()
                if (bare == "a.m" || bare == "p.m"), e < j, chars[e] == "." { e += 1 }
                if s < e { add(s, e) }
                i = j
            }
        }

        /// A hyphenated run of number words ("twenty-one", "twenty-first") becomes one token per word.
        private mutating func add(_ s: Int, _ e: Int) {
            let word = String(chars[s..<e]).lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            if word.contains("-"), !word.hasPrefix("-"), !word.hasSuffix("-") {
                let parts = word.split(separator: "-", omittingEmptySubsequences: false).map(String.init)
                if parts.allSatisfy({ NumberWords.isNumberWord($0) || NumberWords.ordinals.contains($0) }) {
                    var at = s
                    for part in parts {
                        tokens.append(Token(start: at, end: at + part.count, lower: part))
                        at += part.count + 1
                    }
                    return
                }
            }
            tokens.append(Token(start: s, end: e, lower: word))
        }

        // MARK: Gaps

        private func gap(_ a: Int, _ b: Int) -> Gap {
            let from = tokens[a].end, to = tokens[b].start
            guard from <= to else { return .boundary }
            let between = chars[from..<to]
            if between.allSatisfy(TextScan.isSpace), !between.isEmpty { return .space }
            if between.count == 1, between.first == "-" { return .hyphen }
            var commas = 0
            for c in between {
                if c == "," { commas += 1 } else if !TextScan.isSpace(c) { return .boundary }
            }
            return commas == 1 ? .comma : .boundary
        }

        private func inside(_ a: Int, _ b: Int) -> Bool {
            let g = gap(a, b)
            return g == .space || g == .hyphen
        }

        private func linked(_ a: Int, _ b: Int) -> Bool {
            let g = gap(a, b)
            return g == .space || g == .comma
        }

        // MARK: Values

        private func numeric(_ s: String) -> Bool {
            guard let f = s.first, f.isNumber, let l = s.last, l.isNumber else { return false }
            var dots = 0
            for c in s {
                if c == "." { dots += 1 } else if !(c.isNumber || c == ",") { return false }
            }
            return dots <= 1
        }

        private func isNumberLike(_ i: Int) -> Bool {
            let w = tokens[i].lower
            return numeric(w) || NumberWords.isNumberWord(w) || NumberWords.ordinals.contains(w)
        }

        private func isMeridiemWord(_ w: String) -> Bool {
            ["am", "pm", "a.m.", "p.m.", "a.m", "p.m"].contains(w)
        }

        /// Tokens a meridiem takes after index `i`, 0 when there is none.
        private func meridiem(after i: Int) -> Int {
            guard i + 1 < tokens.count, inside(i, i + 1) else { return 0 }
            if isMeridiemWord(tokens[i + 1].lower) { return 1 }
            if tokens[i + 1].lower == "a" || tokens[i + 1].lower == "p", i + 2 < tokens.count, inside(i + 1, i + 2),
               tokens[i + 2].lower == "m" {
                return 2
            }
            return 0
        }

        private func meridiemSuffix(from start: Int, to end: Int) -> String {
            for i in (start..<end).reversed() {
                let word = tokens[i].lower
                let split = (word == "a" || word == "p") && i + 1 < end
                    && tokens[i + 1].lower == "m" && inside(i, i + 1)
                if isMeridiemWord(word) || split { return word.hasPrefix("p") ? " PM" : " AM" }
            }
            return ""
        }

        /// Value of the number words in `from..<to`, nil when they do not parse as one cardinal.
        private func cardinal(_ from: Int, _ to: Int) -> Int? {
            if to - from == 1, tokens[from].lower == "zero" { return 0 }
            var total = 0, current = 0
            var lastScale = Int.max
            var prev = ""
            for k in from..<to {
                let t = tokens[k].lower
                if let v = NumberWords.units[t] {
                    guard current % 100 == 0 || (current % 100 >= 20 && current % 10 == 0) else { return nil }
                    current += v
                } else if let v = NumberWords.teens[t] ?? NumberWords.tens[t] {
                    guard current % 100 == 0 else { return nil }
                    current += v
                } else if t == "hundred" {
                    guard current >= 1, current <= 9 else { return nil }
                    current *= 100
                } else if let scale = NumberWords.scales[t] {
                    guard current >= 1, current <= 999, scale < lastScale else { return nil }
                    total += current * scale
                    current = 0
                    lastScale = scale
                } else if t == "and" {
                    guard prev == "hundred" || NumberWords.scales[prev] != nil, k + 1 < to else { return nil }
                } else {
                    return nil
                }
                prev = t
            }
            return total + current
        }

        /// Every end index at which the number words starting at `s` form a valid cardinal, with its value.
        private func cardinalRuns(from s: Int) -> [(end: Int, value: Int)] {
            guard NumberWords.isNumberWord(tokens[s].lower) else { return [] }
            var out: [(Int, Int)] = []
            var k = s
            while k < tokens.count {
                if k > s, !inside(k - 1, k) { break }
                let w = tokens[k].lower
                guard NumberWords.isNumberWord(w) || (w == "and" && k > s) else { break }
                if w != "and", let v = cardinal(s, k + 1) { out.append((k + 1, v)) }
                k += 1
            }
            return out
        }

        private func ordinalValue(at i: Int) -> (end: Int, value: Int)? {
            let w = tokens[i].lower
            if let v = SelfCorrection.ordinalValues[w] { return (i + 1, v) }
            if w.count >= 3, ["st", "nd", "rd", "th"].contains(String(w.suffix(2))), let n = Int(w.dropLast(2)) {
                return (i + 1, n)
            }
            // "twenty first" .. "thirty first"
            if let tens = NumberWords.tens[w], tens == 20 || tens == 30, i + 1 < tokens.count, inside(i, i + 1),
               let v = SelfCorrection.ordinalValues[tokens[i + 1].lower], v < 10 {
                return (i + 2, tens + v)
            }
            return nil
        }

        /// All values that start at `s`, shortest first.
        private func candidates(at s: Int) -> [Candidate] {
            let w = tokens[s].lower
            var out: [Candidate] = []

            if SelfCorrection.weekdays.contains(w) { return [Candidate(kind: .weekday, end: s + 1)] }
            if SelfCorrection.months.contains(w) {
                out.append(Candidate(kind: .month, end: s + 1))
                if s + 1 < tokens.count, inside(s, s + 1) {
                    if let o = ordinalValue(at: s + 1), (1...31).contains(o.value) {
                        out.append(Candidate(kind: .monthDay, end: o.end))
                    } else if numeric(tokens[s + 1].lower), let d = Int(tokens[s + 1].lower), (1...31).contains(d) {
                        out.append(Candidate(kind: .monthDay, end: s + 2))
                    } else {
                        for run in cardinalRuns(from: s + 1) where (1...31).contains(run.value) {
                            out.append(Candidate(kind: .monthDay, end: run.end))
                        }
                    }
                }
                return out
            }
            if let o = ordinalValue(at: s) { return [Candidate(kind: .ordinal, end: o.end)] }

            // Symbols glued to digits.
            if let first = w.first, "$£€".contains(first), numeric(String(w.dropFirst())) {
                return [Candidate(kind: .money, end: s + 1)]
            }
            if w.hasSuffix("%"), numeric(String(w.dropLast())) { return [Candidate(kind: .percent, end: s + 1)] }

            // Clock time as digits: 2:30, optionally with a meridiem.
            if w.contains(":"), w.count <= 5 {
                let parts = w.split(separator: ":", omittingEmptySubsequences: false)
                if parts.count == 2, parts[1].count == 2, let h = Int(parts[0]), (0...24).contains(h), let m = Int(parts[1]), m < 60 {
                    out.append(Candidate(kind: .time, end: s + 1))
                    let m = meridiem(after: s)
                    if m > 0 { out.append(Candidate(kind: .time, end: s + 1 + m)) }
                    return out
                }
            }

            // Number: digits or words, each valid end, then what can follow it.
            var runs: [(end: Int, value: Int)] = []
            if numeric(w) {
                if let v = Int(w.replacingOccurrences(of: ",", with: "")) { runs = [(s + 1, v)] } else {
                    runs = [(s + 1, -1)]
                }
            } else {
                runs = cardinalRuns(from: s)
            }
            for run in runs {
                var end = run.end
                var value = run.value
                // "three point five"
                if end + 1 < tokens.count, tokens[end].lower == "point", inside(end - 1, end) {
                    var k = end + 1
                    var digits = 0
                    while k < tokens.count, inside(k - 1, k), NumberWords.units[tokens[k].lower] != nil || tokens[k].lower == "zero" {
                        digits += 1
                        k += 1
                    }
                    if digits > 0 { end = k; value = -1 }
                }
                if end < tokens.count, inside(end - 1, end) {
                    let next = tokens[end].lower
                    if next == "percent" {
                        out.append(Candidate(kind: .percent, end: end + 1))
                        continue
                    }
                    if SelfCorrection.moneyWords.contains(next) {
                        out.append(Candidate(kind: .money, end: end + 1))
                        continue
                    }
                    if next == "o'clock", (1...12).contains(value) {
                        out.append(Candidate(kind: .time, end: end + 1))
                        continue
                    }
                }
                out.append(Candidate(kind: .number, end: end))
                guard (1...12).contains(value), end == run.end else { continue }
                let m = meridiem(after: end - 1)
                if m > 0 { out.append(Candidate(kind: .time, end: end + m)) }
                // "two thirty": an hour word and a minute run of 10 to 59, or "oh five".
                guard end < tokens.count, inside(end - 1, end) else { continue }
                if tokens[end].lower == "oh" || tokens[end].lower == "o", end + 1 < tokens.count, inside(end, end + 1),
                   let u = NumberWords.units[tokens[end + 1].lower] {
                    _ = u
                    var stop = end + 2
                    let after = meridiem(after: stop - 1)
                    stop += after
                    out.append(Candidate(kind: .time, end: stop))
                } else if !numeric(w), let minutes = cardinalRuns(from: end).last(where: { (10...59).contains($0.value) }) {
                    var stop = minutes.end
                    stop += meridiem(after: stop - 1)
                    out.append(Candidate(kind: .time, end: stop))
                }
            }
            return out
        }

        // MARK: Matching

        private func cueLength(at c: Int) -> Int? {
            for cue in SelfCorrection.cues {
                guard c + cue.count <= tokens.count else { continue }
                var ok = true
                for (k, word) in cue.enumerated() {
                    if tokens[c + k].lower != word { ok = false; break }
                    if k > 0 {
                        let g = gap(c + k - 1, c + k)
                        let allowed = g == .space || (g == .comma && SelfCorrection.commaCues.contains(cue))
                        if !allowed { ok = false; break }
                    }
                }
                if ok {
                    if SelfCorrection.commaAfterCues.contains(cue) {
                        let after = c + cue.count
                        guard after < tokens.count, gap(after - 1, after) == .comma else { return nil }
                    }
                    return cue.count
                }
            }
            return nil
        }

        /// The earliest start whose value ends exactly at `cue`, with that value's kinds.
        private func valueBefore(_ cue: Int) -> (start: Int, kinds: [Kind])? {
            var found: (Int, [Kind])?
            var s = cue - 1
            while s >= 0, s >= cue - 7 {
                if s + 1 < cue, !linked(s, s + 1) && !inside(s, s + 1) { break }
                let kinds = candidates(at: s).filter { $0.end == cue }.map(\.kind)
                if !kinds.isEmpty { found = (s, kinds) }
                s -= 1
            }
            return found
        }

        func spans() -> [TextSpan] {
            var out: [TextSpan] = []
            var c = 1
            while c < tokens.count {
                guard let length = cueLength(at: c), linked(c - 1, c), let a = valueBefore(c) else { c += 1; continue }
                // Part of a longer number to the left: not a clean A.
                if a.start > 0, inside(a.start - 1, a.start), isNumberLike(a.start - 1) { c += 1; continue }
                let lead = a.start > 0 && linked(a.start - 1, a.start) ? tokens[a.start - 1].lower : nil

                var last: (start: Int, end: Int, bareHour: Int?)?
                var cursor = c
                var cueAt = c
                var length_ = length
                while true {
                    guard let found = value(after: cueAt + length_ - 1, kinds: a.kinds, lead: lead) else { break }
                    last = found
                    cursor = found.end
                    // A second correction straight after: "two, actually three, no wait, four".
                    guard cursor < tokens.count, linked(cursor - 1, cursor), let again = cueLength(at: cursor) else { break }
                    cueAt = cursor
                    length_ = again
                }
                guard let last else { c += 1; continue }

                let start = tokens[a.start].start
                let end = tokens[last.end - 1].end
                var replacement = last.bareHour.map { "\($0):00" + meridiemSuffix(from: a.start, to: last.start) } ?? String(chars[tokens[last.start].start..<end])
                if chars[start].isUppercase, let f = replacement.first, f.isLowercase {
                    replacement = f.uppercased() + replacement.dropFirst()
                }
                out.append(TextSpan(range: start..<end, replacement: replacement))
                c = last.end + 1
            }
            return out
        }

        /// B straight after the cue that ends at `cueEnd`: the longest value of one of A's kinds, after an optional
        /// repeat of the word that stood before A.
        private func value(after cueEnd: Int, kinds: [Kind], lead: String?) -> (start: Int, end: Int, bareHour: Int?)? {
            var b = cueEnd + 1
            guard b < tokens.count, linked(cueEnd, b) else { return nil }
            if SelfCorrection.prepositions.contains(tokens[b].lower) {
                guard tokens[b].lower == lead, b + 1 < tokens.count, inside(b, b + 1) else { return nil }
                b += 1
            }
            let values = candidates(at: b)
            if let best = values.filter({ kinds.contains($0.kind) }).map(\.end).max() { return (b, best, nil) }
            let sentenceEnd = b + 1 == tokens.count || chars[tokens[b].end..<tokens[b + 1].start]
                .contains(where: { $0 == "." || $0 == "!" || $0 == "?" })
            if kinds.contains(.time), values.contains(where: { $0.kind == .number && $0.end == b + 1 }),
               let hour = NumberWords.units[tokens[b].lower] ?? NumberWords.teens[tokens[b].lower] ?? Int(tokens[b].lower),
               (1...12).contains(hour), sentenceEnd {
                return (b, b + 1, hour)
            }
            return nil
        }
    }
}
