import Foundation

/// A small, conservative spoken-number formatter in plain Swift.
///
/// Handles:
/// - cardinals in words up to the billions, with "and" ("two hundred and five" -> 205, "twenty one" -> 21,
///   hyphenated "twenty-one" too)
/// - decimals with "point" ("three point one four" -> 3.14)
/// - percentages ("fifty percent" -> 50%)
/// - dollar amounts ("twenty dollars" -> $20, "five dollars and fifty cents" -> $5.50)
/// - clock times: "two thirty p m" -> 2:30 PM, "five p m" -> 5 PM, "five o'clock" -> 5:00 (also "a.m."/"pm")
///
/// Limits, on purpose:
/// - A lone number below ten stays a word ("two apples", "no one", "one of them", "the one I want"), unless a
///   percent, dollar, decimal or clock context makes it clearly a figure.
/// - Anything ambiguous is left untouched: a run of number words that does not parse as one number ("twenty
///   twenty five", "one two three", "five and ten"), bare "hundred"/"thousand" ("a hundred people"), ordinals
///   ("twenty first"), dates, phone numbers, "cents" on their own, currencies other than dollars.
/// - "two thirty" with no a m / p m / o'clock is not read as a time.
/// - No thousands separators: "twelve thousand" is "12000".
public struct SpokenNumberFormatter: NumberFormatting {
    public init() {}

    public func spans(in text: String) -> [TextSpan] {
        let chars = Array(text)
        guard !chars.isEmpty else { return [] }
        let lower = TextScan.lowered(chars)
        let words = TextScan.words(chars, lower)
        var scanner = Scanner(chars: chars, lower: lower, words: words)
        scanner.run()
        return scanner.spans
    }

    private struct Run {
        var end: Int          // exclusive word index
        var value: Int?       // nil when the run does not parse as one number
    }

    private struct Scanner {
        let chars: [Character]
        let lower: [Character]
        let words: [ScanWord]
        var spans: [TextSpan] = []

        init(chars: [Character], lower: [Character], words: [ScanWord]) {
            self.chars = chars
            self.lower = lower
            self.words = words
        }

        mutating func run() {
            var i = 0
            while i < words.count {
                if let (span, next) = time(at: i) {
                    spans.append(span)
                    i = next
                    continue
                }
                guard isNumberToken(i), words[i].lower != "and" else { i += 1; continue }
                let r = scanRun(from: i)
                if let (span, next) = number(at: i, run: r) {
                    spans.append(span)
                    i = next
                } else {
                    i = max(r.end, i + 1)
                }
            }
        }

        // MARK: Helpers

        func isNumberToken(_ i: Int) -> Bool {
            let w = words[i].lower
            return w == "and" || NumberWords.isNumberWord(w)
        }

        /// Gap between two words is spaces/tabs only, or (when `hyphen`) a single hyphen.
        func gap(_ a: Int, _ b: Int, hyphen: Bool = false) -> Bool {
            let s = words[a].end, e = words[b].start
            guard s < e else { return false }
            if TextScan.onlySpaces(chars, s, e) { return true }
            return hyphen && e - s == 1 && chars[s] == "-"
        }

        func span(_ a: Int, _ b: Int, _ text: String) -> TextSpan {
            TextSpan(range: words[a].start..<words[b].end, replacement: text)
        }

        // MARK: Cardinal runs

        func scanRun(from i: Int) -> Run {
            var j = i
            while j < words.count, isNumberToken(j) {
                if j > i, !gap(j - 1, j, hyphen: true) { break }
                j += 1
            }
            while j > i, words[j - 1].lower == "and" { j -= 1 }
            return Run(end: j, value: parse(i, j))
        }

        func parse(_ from: Int, _ to: Int) -> Int? {
            if to - from == 1, words[from].lower == "zero" { return 0 }
            var total = 0, current = 0
            var lastScale = Int.max
            var prev = ""
            for k in from..<to {
                let t = words[k].lower
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
                    let (part, overflow) = current.multipliedReportingOverflow(by: scale)
                    guard !overflow else { return nil }
                    total += part
                    current = 0
                    lastScale = scale
                } else if t == "and" {
                    guard prev == "hundred" || NumberWords.scales[prev] != nil, k + 1 < to else { return nil }
                    let nxt = words[k + 1].lower
                    guard NumberWords.units[nxt] != nil || NumberWords.teens[nxt] != nil || NumberWords.tens[nxt] != nil
                    else { return nil }
                } else {
                    return nil
                }
                prev = t
            }
            return total + current
        }

        // MARK: Numbers, percent, dollars, decimals

        mutating func number(at i: Int, run r: Run) -> (TextSpan, Int)? {
            guard let value = r.value else { return nil }
            let last = r.end - 1
            if r.end < words.count, NumberWords.ordinals.contains(words[r.end].lower), gap(last, r.end, hyphen: true) {
                return nil
            }
            let single = r.end - i == 1

            // Decimal: <int> point <digit>+
            var digits = ""
            var endWord = last
            if r.end < words.count, words[r.end].lower == "point", gap(last, r.end) {
                var k = r.end + 1
                var prevIdx = r.end
                while k < words.count, gap(prevIdx, k),
                      let d = words[k].lower == "zero" ? 0 : NumberWords.units[words[k].lower] {
                    digits += String(d)
                    prevIdx = k
                    k += 1
                }
                if !digits.isEmpty { endWord = prevIdx }
            }
            let hasDecimal = !digits.isEmpty
            let figure = hasDecimal ? "\(value).\(digits)" : String(value)

            // Percent
            if endWord + 1 < words.count, words[endWord + 1].lower == "percent", gap(endWord, endWord + 1) {
                return (span(i, endWord + 1, figure + "%"), endWord + 2)
            }
            // Dollars (whole amounts only)
            if !hasDecimal, endWord + 1 < words.count,
               words[endWord + 1].lower == "dollar" || words[endWord + 1].lower == "dollars",
               gap(endWord, endWord + 1) {
                let d = endWord + 1
                if d + 2 < words.count, words[d + 1].lower == "and", gap(d, d + 1), gap(d + 1, d + 2),
                   isNumberToken(d + 2) {
                    let cents = scanRun(from: d + 2)
                    if let c = cents.value, c >= 1, c <= 99, cents.end < words.count,
                       words[cents.end].lower == "cents" || words[cents.end].lower == "cent",
                       gap(cents.end - 1, cents.end) {
                        let cc = c < 10 ? "0\(c)" : "\(c)"
                        return (span(i, cents.end, "$\(value).\(cc)"), cents.end + 1)
                    }
                }
                return (span(i, d, "$\(value)"), d + 1)
            }
            if hasDecimal { return (span(i, endWord, figure), endWord + 1) }
            if single && value < 10 { return nil }
            return (span(i, last, figure), r.end)
        }

        // MARK: Clock times

        func hourValue(_ i: Int) -> Int? {
            let w = words[i].lower
            if let v = NumberWords.units[w] { return v }
            if let v = NumberWords.teens[w], v <= 12 { return v }
            return nil
        }

        func time(at i: Int) -> (TextSpan, Int)? {
            guard let hour = hourValue(i) else { return nil }
            // Reject when this hour word is the tail of a longer number ("twenty two p m").
            if i > 0, isNumberToken(i - 1), words[i - 1].lower != "and", gap(i - 1, i, hyphen: true) { return nil }
            let n = words.count
            let wordEnd = words[i].end

            // <hour> o'clock [meridiem]
            if i + 1 < n, words[i + 1].lower.replacingOccurrences(of: "\u{2019}", with: "'") == "o'clock", gap(i, i + 1) {
                var text = "\(hour):00"
                var endIdx = words[i + 1].end
                if let m = meridiem(after: endIdx) {
                    text += m.isPM ? " PM" : " AM"
                    endIdx = m.end
                }
                return (TextSpan(range: words[i].start..<endIdx, replacement: text), firstWord(atOrAfter: endIdx))
            }
            // <hour> <meridiem>
            if let m = meridiem(after: wordEnd) {
                return (TextSpan(range: words[i].start..<m.end, replacement: "\(hour) \(m.isPM ? "PM" : "AM")"),
                        firstWord(atOrAfter: m.end))
            }
            // <hour> <minutes> <meridiem>
            guard i + 1 < n, gap(i, i + 1) else { return nil }
            var minuteStart = i + 1
            var minutes: Int?
            var minuteEnd = i + 1
            let first = words[minuteStart].lower
            if first == "oh" || first == "o" {
                minuteStart += 1
                if minuteStart < n, gap(minuteStart - 1, minuteStart), let u = NumberWords.units[words[minuteStart].lower] {
                    minutes = u
                    minuteEnd = minuteStart + 1
                }
            } else if isNumberToken(minuteStart), first != "and" {
                let r = scanRun(from: minuteStart)
                if let v = r.value, v >= 10, v <= 59 {
                    minutes = v
                    minuteEnd = r.end
                }
            }
            guard let mm = minutes, let m = meridiem(after: words[minuteEnd - 1].end) else { return nil }
            let text = "\(hour):\(mm < 10 ? "0\(mm)" : "\(mm)") \(m.isPM ? "PM" : "AM")"
            return (TextSpan(range: words[i].start..<m.end, replacement: text), firstWord(atOrAfter: m.end))
        }

        func firstWord(atOrAfter idx: Int) -> Int {
            var k = 0
            while k < words.count, words[k].start < idx { k += 1 }
            return k
        }

        /// "a m", "p m", "am", "pm", "a.m.", "p.m." after at least one space. Returns where it ends.
        func meridiem(after pos: Int) -> (isPM: Bool, end: Int)? {
            let n = chars.count
            var k = pos
            guard k < n, TextScan.isSpace(chars[k]) else { return nil }
            while k < n, TextScan.isSpace(chars[k]) { k += 1 }
            guard k < n, lower[k] == "a" || lower[k] == "p" else { return nil }
            let isPM = lower[k] == "p"
            k += 1
            var dotted = false
            if k < n, chars[k] == "." { dotted = true; k += 1 }
            while k < n, TextScan.isSpace(chars[k]) { k += 1 }
            guard k < n, lower[k] == "m" else { return nil }
            k += 1
            if dotted, k < n, chars[k] == "." {
                // Consume the closing dot only when the sentence plainly carries on.
                var look = k + 1
                while look < n, TextScan.isSpace(chars[look]) { look += 1 }
                if look > k + 1, look < n, chars[look].isLowercase { k += 1 }
            }
            guard k >= n || !TextScan.isWordChar(chars[k]) else { return nil }
            return (isPM, k)
        }
    }
}
