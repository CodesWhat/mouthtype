import Foundation

/// Removes swearing used as an exclamation or for emphasis for the Formal tone, and tidies the punctuation and
/// capitalisation it leaves behind.
///
/// A short, conservative list of whole words, matched case-insensitively and never inside another word
/// ("assess", "class", "Scunthorpe", "shell" are untouched). Only uses that can go without breaking the sentence are
/// removed; the model levels smooth over the rest.
///
/// - Removed: a swear word that opens a sentence or sits between commas as an exclamation ("Shit, I forgot", "Well,
///   fuck, I forgot", "I forgot, shit."), an intensifier directly before the word it modifies ("fucking great",
///   "goddamn car", "damn good"), and the phrases "the fuck", "the hell" ("what the fuck is this" becomes "what is
///   this"), "damn it" and "dammit".
/// - Kept: a swear word that is a noun or the object of a verb ("be an asshole", "talk shit", "piece of shit",
///   "my shit"). Removing those would leave a broken sentence.
/// - "hell" alone and "pissed off" are left out because they are often ordinary speech.
/// - An exclamation takes all the punctuation attached to it ("Fuck!!", "Shit..."), and the next word is
///   capitalised unless it is a saved spelling or looks like an identifier. A sentence that was only the swear word
///   disappears.
/// - Words in `protectedWords` (saved spellings and snippet text) and text matching `protectedPhrases` (saved
///   spelling heard forms, snippet triggers) are never removed.
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
    /// Always an exclamation, wherever they appear.
    private static let standalone: Set<String> = ["dammit", "goddamnit"]
    /// Words that are exclamations when they open a sentence or sit between commas, with punctuation after them.
    private static let interjections: Set<String> = [
        "fuck", "fucking", "motherfucking", "shit", "bullshit", "crap", "damn", "damned", "goddamn", "goddamned",
    ]
    /// Words that are intensifiers when they come directly before the word they modify.
    private static let intensifiers: Set<String> = [
        "fucking", "motherfucking", "shitty", "crappy", "damn", "damned", "goddamn", "goddamned",
    ]

    private let protectedWords: Set<String>
    private let writtenForms: Set<String>
    private let protectedPhrases: [String]

    public init(protectedWords: Set<String> = [], protectedPhrases: [String] = []) {
        self.protectedWords = Set(protectedWords.map { $0.lowercased() })
        self.writtenForms = protectedWords
        self.protectedPhrases = protectedPhrases
    }

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        var scan = Scan(chars: chars, protectedWords: protectedWords, writtenForms: writtenForms, protectedPhrases: protectedPhrases)
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
        let writtenForms: Set<String>
        var inProtectedPhrase: [Bool]
        var removed: [Bool]
        var spans: [TextSpan] = []
        var lastCutEnd = 0

        init(chars: [Character], protectedWords: Set<String>, writtenForms: Set<String>, protectedPhrases: [String]) {
            self.chars = chars
            self.n = chars.count
            let lower = TextScan.lowered(chars)
            self.words = TextScan.words(chars, lower)
            self.protectedWords = protectedWords
            self.writtenForms = writtenForms
            self.removed = [Bool](repeating: false, count: chars.count)
            var covered = [Bool](repeating: false, count: chars.count)
            for hit in PhraseMatcher(patterns: protectedPhrases).matches(chars, lower: lower) {
                for i in hit.range { covered[i] = true }
            }
            self.inProtectedPhrase = covered
        }

        mutating func run() {
            let units = findUnits()
            let starts = Set(units.map(\.first))
            for unit in units { remove(unit, nextUnitStarts: starts) }
        }

        // MARK: Finding

        func isProfane(_ k: Int) -> Bool {
            let w = words[k]
            guard ProfanityRemover.words.contains(w.lower), !protectedWords.contains(w.lower), !isProtected(w) else { return false }
            return !insideToken(w)
        }

        func isProtected(_ w: ScanWord) -> Bool {
            (w.start..<w.end).contains { inProtectedPhrase[$0] }
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
                  !isProtected(words[k]), !isProtected(words[k - 1]), !insideToken(words[k]), !insideToken(words[k - 1]),
                  chars[words[k - 1].end..<words[k].start].allSatisfy(TextScan.isSpace),
                  words[k].start > words[k - 1].end else { return false }
            return true
        }

        func adjacent(_ k: Int) -> Bool {
            k + 1 < words.count && words[k].end < words[k + 1].start && TextScan.onlySpaces(chars, words[k].end, words[k + 1].start)
        }

        func isPunctuation(_ c: Character) -> Bool { ",.!?\u{2026};:".contains(c) }

        /// A word that can only be an exclamation or an intensifier here: it is not a noun or the object of a verb.
        func findUnits() -> [Unit] {
            var units: [Unit] = []
            func add(_ first: Int, _ last: Int) {
                if let previous = units.last, previous.last >= first { return }
                units.append(Unit(first: first, last: last))
            }
            var k = 0
            while k < words.count {
                if isTheHell(k) {
                    add(k - 1, k)
                    k += 1
                    continue
                }
                guard isProfane(k) else { k += 1; continue }
                let lower = words[k].lower
                if ProfanityRemover.standalone.contains(lower) {
                    add(k, k)
                    k += 1
                    continue
                }
                if ProfanityRemover.damnWords.contains(lower), adjacent(k), words[k + 1].lower == "it" {
                    // "damn it" goes as a phrase at the end of a clause; "damn it all" is left alone.
                    let after = words[k + 1].end
                    if after >= n || isPunctuation(chars[after]) || isClauseEnd(after) { add(k, k + 1) }
                    k += 2
                    continue
                }
                if let last = interjectionEnd(from: k) {
                    add(k, last)
                    k = last + 1
                    continue
                }
                if let last = intensifierEnd(from: k) {
                    add(k, last)
                    k = last + 1
                    continue
                }
                k += 1
            }
            return units
        }

        /// The last word of an exclamation starting at `k`, when it opens a sentence or follows a comma and is closed
        /// by punctuation or the end of the text ("Shit,", "Fuck!!", "fucking shit.").
        func interjectionEnd(from k: Int) -> Int? {
            guard ProfanityRemover.interjections.contains(words[k].lower) else { return nil }
            var last = k
            while adjacent(last), isProfane(last + 1), ProfanityRemover.interjections.contains(words[last + 1].lower) { last += 1 }
            let s = words[k].start, e = words[last].end
            var j = s - 1
            while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
            guard j >= 0 && chars[j] == "," || sentenceStart(before: s) else { return nil }
            guard e >= n || isPunctuation(chars[e]) || isClauseEnd(e) else { return nil }
            return last
        }

        /// The last word of a run of intensifiers directly before the word they modify ("fucking great").
        func intensifierEnd(from k: Int) -> Int? {
            func modifies(_ i: Int) -> Bool {
                isProfane(i) && ProfanityRemover.intensifiers.contains(words[i].lower) && adjacent(i)
                    && !(ProfanityRemover.damnWords.contains(words[i].lower) && words[i + 1].lower == "it")
            }
            guard modifies(k) else { return nil }
            var last = k
            while last + 1 < words.count, adjacent(last), modifies(last + 1) { last += 1 }
            return last
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

        /// Whether the word after a removed exclamation keeps its case: a saved spelling, or something that looks like
        /// an identifier (a digit, underscore, dot, slash or @ inside it).
        func keepsCase(_ w: ScanWord) -> Bool {
            if isProtected(w) || writtenForms.contains(String(chars[w.start..<w.end])) { return true }
            if chars[w.start..<w.end].contains(where: { $0.isNumber || $0 == "_" }) { return true }
            if w.end + 1 < n, "./\\@".contains(chars[w.end]), TextScan.isWordChar(chars[w.end + 1]) { return true }
            return false
        }

        mutating func remove(_ unit: Unit, nextUnitStarts: Set<Int>) {
            let s = words[unit.first].start, e = words[unit.last].end
            var post: Character?
            var punctEnd = e
            while punctEnd < n, isPunctuation(chars[punctEnd]) { punctEnd += 1 }
            if punctEnd > e { post = chars[e] }
            var j = s - 1
            while j >= 0, TextScan.isSpace(chars[j]) || removed[j] { j -= 1 }
            let hasPre = j >= 0 && chars[j] == ","
            let preIdx = j
            let atStart = !hasPre && sentenceStart(before: s)
            let afterWord = punctEnd
            let afterSpaces = skipSpaces(from: afterWord)
            let atEnd = afterSpaces >= n || chars[afterSpaces].isNewline

            func trailingBack() -> Int {
                var b = s
                while b > lastCutEnd, TextScan.isSpace(chars[b - 1]) { b -= 1 }
                return b
            }

            if atStart {
                // The swear word, all the punctuation attached to it, and the space after it.
                let cutStart = atEnd ? trailingBack() : s
                add(core: s..<afterWord, cut: cutStart..<(atEnd ? afterWord : afterSpaces))
                if !atEnd, afterSpaces < n, let next = words.firstIndex(where: { $0.start == afterSpaces }),
                   !nextUnitStarts.contains(next), !keepsCase(words[next]), let up = TextScan.capitalized(chars, words[next]) {
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
