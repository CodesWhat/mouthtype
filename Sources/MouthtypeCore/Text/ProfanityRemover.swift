import Foundation

/// Removes swearing for the Formal tone, and tidies the punctuation and capitalisation it leaves behind.
///
/// A short, conservative list of whole words, matched case-insensitively and never inside another word
/// ("assess", "class", "Scunthorpe", "shell" are untouched). "hell" alone and "pissed off" are left out because
/// they are often ordinary speech; "the hell" and "the fuck" go as phrases ("what the fuck is this" becomes
/// "what is this"). "damn it" goes as a phrase too.
///
/// - A swear word that opens a sentence goes with its comma ("Shit, I forgot" becomes "I forgot"), and the next
///   word is capitalised. A sentence that was only the swear word ("Fuck.") disappears.
/// - Mid-sentence, the word goes with the comma in front of it ("I forgot, shit." becomes "I forgot.") or the
///   comma after it.
/// - Words in `protectedWords` (saved spellings and snippet text) are never removed.
/// - Not touched: URL, path, email or hyphenated tokens that happen to contain a listed word.
///
/// English only. Edits are logged under the `filler` stage name, the store's vocabulary has no separate one.
public struct ProfanityRemover: Sendable {
    public static let stageName = FillerRemover.stageName

    public static let words: Set<String> = [
        "fuck", "fucks", "fucked", "fucking", "fucker", "fuckers", "motherfucker", "motherfuckers", "motherfucking",
        "shit", "shits", "shitty", "bullshit",
        "damn", "damned", "goddamn", "goddamned", "goddamnit", "dammit",
        "ass", "asses", "asshole", "assholes",
        "bitch", "bitches", "bitching",
        "crap", "crappy",
    ]

    /// Words that only count after "the", as in "what the fuck".
    static let afterThe: Set<String> = ["fuck", "hell"]
    private static let damnWords: Set<String> = ["damn", "damned", "goddamn", "goddamned"]

    private let protectedWords: Set<String>

    public init(protectedWords: Set<String> = []) {
        self.protectedWords = Set(protectedWords.map { $0.lowercased() })
    }

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        var scan = Scan(chars: chars, protectedWords: protectedWords)
        scan.run()
        return SpanRewriter.apply(scan.spans, to: chars, stage: Self.stageName)
    }

    private struct Unit {
        var first: Int
        var last: Int
    }

    private struct Scan {
        let chars: [Character]
        let n: Int
        let words: [ScanWord]
        let protectedWords: Set<String>
        var removed: [Bool]
        var spans: [TextSpan] = []
        var lastCutEnd = 0

        init(chars: [Character], protectedWords: Set<String>) {
            self.chars = chars
            self.n = chars.count
            self.words = TextScan.words(chars, TextScan.lowered(chars))
            self.protectedWords = protectedWords
            self.removed = [Bool](repeating: false, count: chars.count)
        }

        mutating func run() {
            let units = findUnits()
            let starts = Set(units.map(\.first))
            for unit in units { remove(unit, nextUnitStarts: starts) }
        }

        // MARK: Finding

        func isProfane(_ k: Int) -> Bool {
            let w = words[k]
            guard ProfanityRemover.words.contains(w.lower), !protectedWords.contains(w.lower) else { return false }
            return !insideToken(w)
        }

        /// Next to a path, URL, email, identifier or hyphen, where the word is part of something else.
        func insideToken(_ w: ScanWord) -> Bool {
            let blockers: Set<Character> = ["/", "\\", "@", "_", "`", "-", "#", "$"]
            if w.start > 0 {
                let c = chars[w.start - 1]
                if blockers.contains(c) { return true }
                if c == ".", w.start > 1, TextScan.isWordChar(chars[w.start - 2]) { return true }
            }
            if w.end < n {
                let c = chars[w.end]
                if blockers.contains(c) { return true }
                if c == ".", w.end + 1 < n, TextScan.isWordChar(chars[w.end + 1]) { return true }
            }
            return false
        }

        func isTheHell(_ k: Int) -> Bool {
            guard k > 0, ProfanityRemover.afterThe.contains(words[k].lower), words[k - 1].lower == "the", !protectedWords.contains(words[k].lower),
                  !insideToken(words[k]), !insideToken(words[k - 1]),
                  chars[words[k - 1].end..<words[k].start].allSatisfy(TextScan.isSpace),
                  words[k].start > words[k - 1].end else { return false }
            return true
        }

        func findUnits() -> [Unit] {
            var units: [Unit] = []
            var k = 0
            while k < words.count {
                var first = k
                if isTheHell(k) {
                    first = k - 1
                } else if !isProfane(k) {
                    k += 1
                    continue
                }
                var last = k
                // Absorb adjacent swear words ("fucking shit") and the "it" of "damn it".
                while last + 1 < words.count, TextScan.onlySpaces(chars, words[last].end, words[last + 1].start),
                      words[last].end < words[last + 1].start, isProfane(last + 1) {
                    last += 1
                }
                if ProfanityRemover.damnWords.contains(words[last].lower), last + 1 < words.count,
                   words[last + 1].lower == "it", TextScan.onlySpaces(chars, words[last].end, words[last + 1].start),
                   words[last].end < words[last + 1].start {
                    let after = words[last + 1].end
                    if after >= n || ",.!?\u{2026};:".contains(chars[after]) || chars[after].isWhitespace && isClauseEnd(after) {
                        last += 1
                    }
                }
                if let previous = units.last, previous.last >= first { k = last + 1; continue }
                units.append(Unit(first: first, last: last))
                k = last + 1
            }
            return units
        }

        func isClauseEnd(_ i: Int) -> Bool {
            var j = i
            while j < n, TextScan.isSpace(chars[j]) { j += 1 }
            return j >= n || chars[j].isNewline || ",.!?\u{2026};:".contains(chars[j])
        }

        // MARK: Removing

        func sentenceStart(before pos: Int) -> Bool {
            var i = pos - 1
            while i >= 0, chars[i].isWhitespace || removed[i] {
                if chars[i].isNewline { return true }
                i -= 1
            }
            if i < 0 { return true }
            return ".!?\u{2026}".contains(chars[i])
        }

        mutating func add(core: Range<Int>, cut: Range<Int>) {
            let cutStart = max(cut.lowerBound, lastCutEnd)
            spans.append(TextSpan(range: core, cut: cutStart..<cut.upperBound, replacement: ""))
            lastCutEnd = max(lastCutEnd, cut.upperBound)
            for i in core { removed[i] = true }
        }

        func skipSpaces(from i: Int) -> Int {
            var j = i
            while j < n, TextScan.isSpace(chars[j]) { j += 1 }
            return j
        }

        mutating func remove(_ unit: Unit, nextUnitStarts: Set<Int>) {
            let s = words[unit.first].start, e = words[unit.last].end
            var post: Character?
            if e < n, ",.!?\u{2026};:".contains(chars[e]) { post = chars[e] }
            var j = s - 1
            while j >= 0, TextScan.isSpace(chars[j]) || removed[j] { j -= 1 }
            let hasPre = j >= 0 && chars[j] == ","
            let preIdx = j
            let atStart = !hasPre && sentenceStart(before: s)
            let afterWord = post == nil ? e : e + 1
            let afterSpaces = skipSpaces(from: afterWord)
            let atEnd = afterSpaces >= n || chars[afterSpaces].isNewline

            func trailingBack() -> Int {
                var b = s
                while b > lastCutEnd, TextScan.isSpace(chars[b - 1]) { b -= 1 }
                return b
            }

            if atStart {
                // The swear word, its comma or closing mark, and the space after it.
                if post == ";" || post == ":" {
                    let cutStart = atEnd ? trailingBack() : s
                    add(core: s..<e, cut: cutStart..<(atEnd ? e : skipSpaces(from: e)))
                    return
                }
                let cutStart = atEnd ? trailingBack() : s
                add(core: s..<afterWord, cut: cutStart..<(atEnd ? afterWord : afterSpaces))
                if !atEnd, afterSpaces < n, let next = words.firstIndex(where: { $0.start == afterSpaces }),
                   !nextUnitStarts.contains(next), let up = TextScan.capitalized(chars, words[next]) {
                    spans.append(TextSpan(range: words[next].start..<words[next].end, replacement: up))
                    lastCutEnd = max(lastCutEnd, words[next].end)
                }
            } else if hasPre, preIdx >= lastCutEnd, post == "," || post == nil && atEnd || post.map({ ".!?\u{2026}".contains($0) }) == true {
                // "well, fuck, so" leaves "well, so"; "forgot, shit." leaves "forgot.".
                add(core: preIdx..<e, cut: preIdx..<e)
            } else if post == "," {
                add(core: s..<afterWord, cut: s..<afterSpaces)
            } else if post != nil, atEnd || ".!?\u{2026};:".contains(post!) {
                add(core: s..<e, cut: trailingBack()..<e)
            } else if atEnd {
                add(core: s..<e, cut: trailingBack()..<e)
            } else {
                add(core: s..<e, cut: s..<skipSpaces(from: e))
            }
        }
    }
}
