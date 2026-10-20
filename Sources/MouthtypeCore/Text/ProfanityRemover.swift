import Foundation
import NaturalLanguage

/// Removes swearing used as an exclamation or for emphasis for the Formal tone, and tidies the punctuation and
/// capitalisation it leaves behind.
///
/// A short, conservative list of whole words, matched case-insensitively and never inside another word
/// ("assess", "class", "Scunthorpe", "shell" are untouched). Only uses that can go without breaking the sentence are
/// removed; Thorough's model handles the rest.
///
/// - Removed: a swear word that opens a sentence or sits between commas as an exclamation ("Shit, I forgot", "Well,
///   fuck, I forgot", "I forgot, shit."), an intensifier directly before the word it modifies ("fucking great",
///   "goddamn car", "damn good"), and the phrases "the fuck", "the hell" ("what the fuck is this" becomes "what is
///   this"), "damn it" and "dammit". An intensifier goes only when the part-of-speech tagger says the next word is
///   an adjective, adverb or noun, so "stop fucking around" keeps its verb. Adjective-only forms ("shitty", "crappy", "damned") stay for the model.
/// - A sentence-opening exclamation with no punctuation after it also goes when a new clause follows, judged by the
///   tagger ("Fuck this is a test", "Shit I forgot the keys", "Damn it's cold"). "Fuck this job" keeps its object.
/// - Dismissive phrases go whole ("Fuck you.", "Fuck off", "Fuck that.", "Fuck it, let's go", "Screw you"); a sentence
///   that was only that disappears.
/// - Swapped for a mild word when the sentence needs one (`swaps`, applied after the removals): asshole, bitch and
///   fucker become "jerk" ("an asshole" becomes "a jerk"), bullshit "nonsense", shitty and crappy "bad", crap "junk",
///   noun shit "stuff" ("talk shit" "talk nonsense", "piece of shit" "piece of junk"), "pain in the ass" "pain in the
///   neck", "pissed off" "annoyed", "Fuck this job" "Forget this job", "fuck up", "fucked up" and "fucking / screwing
///   around" use "mess". "damned" before a noun or adjective is dropped.
/// - "hell" alone is left out because it is often ordinary speech.
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
    private static let intensifiers: Set<String> = ["fucking", "motherfucking", "damn", "goddamn"]

    /// Verbs after which "fucking" is the verb itself ("stop fucking around").
    private static let gerundTriggers: Set<String> = [
        "stop", "stopped", "stopping", "quit", "quitting", "keep", "keeps", "kept", "keeping", "start", "started", "starting",
    ]
    /// Copulas and auxiliaries, after which an intensifier can stand before a verb form ("is fucking broken").
    private static let auxiliaries: Set<String> = [
        "is", "are", "was", "were", "am", "be", "been", "being", "has", "have", "had", "will", "would", "can", "could",
        "should", "might", "must", "did", "does", "do", "'s", "'re", "'m",
    ]

    /// Loads the tagger's language model off the dictation path, so the first intensifier doesn't spend the cleanup
    /// time budget on it.
    public static func prewarm() {
        Task.detached(priority: .utility) {
            let probe = "Warm up."
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = probe
            _ = tagger.tag(at: probe.startIndex, unit: .word, scheme: .lexicalClass)
        }
    }

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
        let removed = SpanRewriter.apply(scan.spans, to: chars, stage: Self.stageName)
        // What is left of the swearing is a noun, adjective or verb the sentence needs: swap it for a mild word.
        let tidied = Array(removed.text)
        let swaps = Scan(chars: tidied, protectedWords: protectedWords, writtenForms: writtenForms, protectedPhrases: protectedPhrases)
            .findSwaps()
        guard !swaps.isEmpty else { return removed }
        let swapped = SpanRewriter.apply(swaps, to: tidied, stage: Self.stageName)
        // The swap edits are positioned in the text the removals left; report them against the original.
        let origin = Self.originalOffsets(of: scan.spans, count: chars.count)
        let moved = swapped.edits.map { edit -> EditOp in
            var edit = edit
            edit.position = edit.position < origin.count ? origin[edit.position] : chars.count
            return edit
        }
        return StageResult(text: swapped.text, edits: removed.edits + moved)
    }

    /// For each character of the text `SpanRewriter` produces from `spans`, where it sat in the original.
    private static func originalOffsets(of spans: [TextSpan], count: Int) -> [Int] {
        var map: [Int] = []
        var cursor = 0
        let ordered = spans.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        for span in ordered {
            guard span.range.lowerBound >= cursor, span.cut.upperBound <= count,
                  span.cut.lowerBound <= span.range.lowerBound, span.cut.upperBound >= span.range.upperBound else { continue }
            let cutStart = max(span.cut.lowerBound, cursor)
            map.append(contentsOf: cursor..<cutStart)
            for i in 0..<span.replacement.count { map.append(min(span.range.lowerBound + i, span.cut.upperBound - 1)) }
            cursor = span.cut.upperBound
        }
        map.append(contentsOf: cursor..<count)
        return map
    }

    /// Swear words that have a mild stand-in wherever they appear.
    static let swaps: [String: String] = [
        "asshole": "jerk", "assholes": "jerks", "bitch": "jerk", "bitches": "jerks", "fucker": "jerk", "fuckers": "jerks",
        "motherfucker": "jerk", "motherfuckers": "jerks", "bullshit": "nonsense", "shitty": "bad", "crappy": "bad",
        "crap": "junk", "bitching": "complaining",
    ]
    /// "fuck up", "fucked up", "fucking around" and so on.
    private static let messForms: [String: String] = ["fuck": "mess", "fucks": "messes", "fucked": "messed", "fucking": "messing"]
    private static let talkVerbs: Set<String> = ["talk", "talks", "talked", "talking"]
    /// Adjective forms dropped before the noun they modify.
    private static let droppedAdjectives: Set<String> = ["damned", "goddamned"]

    /// Part-of-speech tags for the characters of a text, computed only when an intensifier needs one.
    private final class LexicalClasses {
        private let text: String
        private let indices: [String.Index]
        private lazy var tagger: NLTagger = {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = text
            return tagger
        }()

        init(_ chars: [Character]) {
            text = String(chars)
            indices = Array(text.indices)
        }

        func lexicalClass(at offset: Int) -> NLTag? {
            guard offset < indices.count else { return nil }
            return tagger.tag(at: indices[offset], unit: .word, scheme: .lexicalClass).0
        }
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
        let tags: LexicalClasses
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
            self.tags = LexicalClasses(chars)
            self.removed = [Bool](repeating: false, count: chars.count)
            var covered = [Bool](repeating: false, count: chars.count)
            // Each phrase on its own, so overlapping phrases ("oh my", "my damn project") all keep their cover.
            for phrase in Set(protectedPhrases) {
                for hit in PhraseMatcher(patterns: [phrase]).matches(chars, lower: lower) {
                    for i in hit.range { covered[i] = true }
                }
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
                if let last = holyEnd(from: k) ?? dismissiveEnd(from: k) {
                    add(k, last)
                    k = last + 1
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
                    // "damn it" goes as a phrase at the end of a clause; "damn it all" is left alone. A protected "it"
                    // (a saved spelling) keeps the whole phrase.
                    let after = words[k + 1].end
                    let itIsProtected = isProtected(words[k + 1]) || protectedWords.contains("it")
                    if !itIsProtected, after >= n || isPunctuation(chars[after]) || isClauseEnd(after) { add(k, k + 1) }
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

        /// A word that can be edited here: not saved, not protected, not part of a token.
        func isFree(_ k: Int) -> Bool {
            !protectedWords.contains(words[k].lower) && !isProtected(words[k]) && !insideToken(words[k])
        }

        /// "Holy shit" as an exclamation: both words go.
        func holyEnd(from k: Int) -> Int? {
            guard words[k].lower == "holy", isFree(k), adjacent(k), isProfane(k + 1),
                  ["shit", "crap", "fuck"].contains(words[k + 1].lower) else { return nil }
            return k + 1
        }

        /// "Fuck you", "fuck off", "fuck that", "fuck it", "screw you": a dismissal that can go whole. "that" and "this"
        /// only when nothing follows; with an object they become "Forget ..." (see `findSwaps`). "it" may also be
        /// followed by a new clause ("Fuck it let's go").
        func dismissiveEnd(from k: Int) -> Int? {
            let verb = words[k].lower
            guard verb == "fuck" || verb == "screw", isFree(k), adjacent(k), isFree(k + 1) else { return nil }
            let target = words[k + 1].lower
            guard ["you", "yourself", "off", "that", "this", "it"].contains(target) else { return nil }
            if verb == "screw" {
                var j = words[k].start - 1
                while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
                guard sentenceStart(before: words[k].start) || (j >= 0 && chars[j] == ",") else { return nil }
            }
            let after = words[k + 1].end
            if after >= n || isPunctuation(chars[after]) || isClauseEnd(after) { return k + 1 }
            if target == "it", sentenceStart(before: words[k].start), adjacent(k + 1), k + 2 < words.count,
               startsClause(at: k + 2) || ["i", "we", "they", "he", "she"].contains(words[k + 2].lower) { return k + 1 }
            return nil
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
            if e >= n || isPunctuation(chars[e]) || isClauseEnd(e) { return last }
            // No comma after a spoken opener ("Fuck this is a test"): it goes when a new clause follows.
            guard sentenceStart(before: s), adjacent(last), startsClause(at: last + 1) else { return nil }
            return last
        }

        /// Whether the words from `k` begin a clause of their own: a pronoun or determiner, then a verb ("this is",
        /// "I forgot", "it's"). A noun after it means the swear word takes an object ("Fuck this job").
        func startsClause(at k: Int) -> Bool {
            guard k < words.count else { return false }
            if Self.contractedSubjects.contains(words[k].lower) { return true }
            guard k + 1 < words.count, adjacent(k),
                  let a = tags.lexicalClass(at: words[k].start), a == .pronoun || a == .determiner,
                  let b = tags.lexicalClass(at: words[k + 1].start), b == .verb else { return false }
            return true
        }

        static let contractedSubjects: Set<String> = {
            var result: Set<String> = []
            for subject in ["it", "he", "she", "that", "there", "here", "what", "who", "let"] {
                for suffix in ["'s", "\u{2019}s", "'ll", "\u{2019}ll", "'d", "\u{2019}d"] { result.insert(subject + suffix) }
            }
            for subject in ["i", "you", "we", "they"] {
                for suffix in ["'m", "'re", "'ve", "'ll", "'d"] {
                    result.insert(subject + suffix)
                    result.insert(subject + suffix.replacingOccurrences(of: "'", with: "\u{2019}"))
                }
            }
            return result
        }()

        /// The last word of a run of intensifiers directly before the word they modify ("fucking great").
        func intensifierEnd(from k: Int) -> Int? {
            func modifies(_ i: Int) -> Bool {
                isProfane(i) && ProfanityRemover.intensifiers.contains(words[i].lower) && adjacent(i)
                    && !(ProfanityRemover.damnWords.contains(words[i].lower) && words[i + 1].lower == "it")
            }
            guard modifies(k), modifiesNext(k) else { return nil }
            var last = k
            while last + 1 < words.count, adjacent(last), modifies(last + 1), modifiesNext(last + 1) { last += 1 }
            return last
        }

        /// Whether the swear word at `k` only emphasises the word after it, judged from that word's part of speech
        /// (the tagger reads the swear word itself as a verb far too often to ask it). A noun, adjective or adverb
        /// follows an intensifier; a preposition, particle or pronoun means it is the verb ("stop fucking around",
        /// "fucking it up"), and so does a verb that comes right after "stop", "keep", "quit" or "start". A verb
        /// follows an intensifier only after a copula or auxiliary ("is fucking broken"). With no tag the word stays.
        func modifiesNext(_ k: Int) -> Bool {
            guard k + 1 < words.count, let next = tags.lexicalClass(at: words[k + 1].start) else { return false }
            let previous = k > 0 && adjacent(k - 1) ? words[k - 1].lower : nil
            if let previous, ProfanityRemover.gerundTriggers.contains(previous) { return false }
            switch next {
            case .adjective, .adverb, .interjection: return true
            case .noun: return true
            case .verb: return previous.map(ProfanityRemover.auxiliaries.contains) ?? false
            default: return false
            }
        }

        // MARK: Swapping

        /// `replacement` with the first letter in the case of the word it replaces.
        func matchingCase(_ replacement: String, like w: ScanWord) -> String {
            guard chars[w.start].isUppercase, let first = replacement.first else { return replacement }
            return first.uppercased() + replacement.dropFirst()
        }

        /// Mild stand-ins for the swearing that is still in the text after the removals.
        func findSwaps() -> [TextSpan] {
            var spans: [TextSpan] = []
            func replace(_ k: Int, _ with: String) {
                spans.append(TextSpan(range: words[k].start..<words[k].end, replacement: matchingCase(with, like: words[k])))
            }
            func nextIs(_ k: Int, _ options: Set<String>) -> Bool {
                adjacent(k) && options.contains(words[k + 1].lower) && isFree(k + 1)
            }
            var k = 0
            while k < words.count {
                let lower = words[k].lower
                if lower == "pissed", isFree(k), nextIs(k, ["off"]) {
                    spans.append(TextSpan(range: words[k].start..<words[k + 1].end, replacement: matchingCase("annoyed", like: words[k])))
                    k += 2
                    continue
                }
                if lower == "screwing", isFree(k), nextIs(k, ["around"]) {
                    replace(k, "messing")
                    k += 1
                    continue
                }
                guard ProfanityRemover.words.contains(lower), isProfane(k) else { k += 1; continue }
                defer { k += 1 }
                if let mess = ProfanityRemover.messForms[lower], nextIs(k, ["up", "around"]) {
                    replace(k, mess)
                } else if lower == "fuck", nextIs(k, ["this", "that"]), adjacent(k + 1) {
                    replace(k, "forget")
                } else if lower == "ass", k >= 3, adjacent(k - 1), adjacent(k - 2), adjacent(k - 3),
                          words[k - 1].lower == "the", words[k - 2].lower == "in", words[k - 3].lower == "pain" {
                    replace(k, "neck")
                } else if ProfanityRemover.droppedAdjectives.contains(lower), adjacent(k), modifiesNext(k) {
                    let next = words[k + 1]
                    let kept = sentenceStart(before: words[k].start) && !keepsCase(next)
                        ? TextScan.capitalized(chars, next) ?? String(chars[next.start..<next.end]) : String(chars[next.start..<next.end])
                    spans.append(TextSpan(range: words[k].start..<next.end, replacement: kept))
                    k += 1
                } else if lower == "shit" {
                    if k > 0, adjacent(k - 1), ProfanityRemover.talkVerbs.contains(words[k - 1].lower) {
                        replace(k, "nonsense")
                    } else if k > 1, adjacent(k - 1), adjacent(k - 2), words[k - 1].lower == "of", words[k - 2].lower == "piece" {
                        replace(k, "junk")
                    } else {
                        replace(k, "stuff")
                    }
                } else if let mild = ProfanityRemover.swaps[lower] {
                    if mild.hasPrefix("jerk"), k > 0, adjacent(k - 1), words[k - 1].lower == "an", isFree(k - 1) {
                        // "an asshole" becomes "a jerk".
                        let between = String(chars[words[k - 1].end..<words[k].start])
                        spans.append(TextSpan(
                            range: words[k - 1].start..<words[k].end,
                            replacement: matchingCase("a", like: words[k - 1]) + between + mild))
                    } else {
                        replace(k, mild)
                    }
                }
            }
            return spans
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

        /// Whether the word right before the comma at `comma` is a conjunction, so the comma is only there for the
        /// exclamation that follows.
        func followsConjunction(commaAt comma: Int) -> Bool {
            guard let word = words.last(where: { $0.end == comma }) else { return false }
            return ["and", "but", "so", "or", "because", "that", "if", "then", "when", "while"].contains(word.lower)
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
            } else if hasPre, preIdx >= lastCutEnd, post == ",", followsConjunction(commaAt: preIdx) {
                // "and, fuck, it broke" leaves "and it broke": both commas only set off the exclamation.
                add(core: preIdx..<afterWord, cut: preIdx..<afterWord)
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
