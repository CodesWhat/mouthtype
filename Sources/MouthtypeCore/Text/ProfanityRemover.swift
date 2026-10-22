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
///   around" use "mess" (also split: "fucked it up"). "damned" before a noun or adjective is dropped, and the noun
///   still gets its own swap. Verb forms get verb swaps by position ("I shit you not" "I kid you not", "she bitches
///   about work" "she complains about work", "he shits on it" "he dumps on it"); a leftover "fuck" verb is "mess with",
///   "cheat" ("fucked us over"), "sleep with" (a person as the object) or, as a last resort, "mess up", so no listed
///   word survives except the "damn" family when it is not an exclamation or intensifier.
///   "a" or "an" before an edited spot is recomputed ("an asshole" "a jerk", "a fucking idiot" "an idiot").
/// - "hell" alone is left out because it is often ordinary speech.
/// - An exclamation takes all the punctuation attached to it ("Fuck!!", "Shit..."), and the next word is
///   capitalised unless it is a saved spelling or looks like an identifier. A sentence that was only the swear word
///   disappears.
/// - Words in `protectedWords` (saved spellings and snippet text) and text matching `protectedPhrases` (saved
///   spelling heard forms, snippet triggers) are never removed.
/// - Not touched: URL, path, email or hyphenated tokens that happen to contain a listed word.
///
/// English only. Edits are logged under the `profanity` stage name.
public struct ProfanityRemover: Sendable {
    public static let stageName = "profanity"

    public static let words: Set<String> = [
        "fuck", "fucks", "fucked", "fucking", "fucker", "fuckers", "motherfucker", "motherfuckers", "motherfucking",
        "shit", "shits", "shitting", "shitty", "bullshit",
        "damn", "damned", "goddamn", "goddamned", "goddamnit", "dammit",
        "ass", "asses", "asshole", "assholes",
        "bitch", "bitches", "bitched", "bitching", "bitchin",
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
            tagger.setLanguage(.english, range: probe.startIndex..<probe.endIndex)
            _ = tagger.tag(at: probe.startIndex, unit: .word, scheme: .lexicalClass)
        }
    }

    private let protectedWords: Set<String>
    private let writtenForms: Set<String>
    private let phraseMatcher: PhraseMatcher

    public init(protectedWords: Set<String> = [], protectedPhrases: [String] = []) {
        self.protectedWords = Set(protectedWords.map { $0.lowercased() })
        self.writtenForms = protectedWords
        self.phraseMatcher = PhraseMatcher(patterns: protectedPhrases)
    }

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        var scan = Scan(chars: chars, protectedWords: protectedWords, writtenForms: writtenForms, phraseMatcher: phraseMatcher)
        scan.run()
        let removed = SpanRewriter.apply(scan.spans, to: chars, stage: Self.stageName)
        // What is left of the swearing is a noun, adjective or verb the sentence needs: swap it for a mild word.
        let tidied = Array(removed.text)
        let swaps = Scan(chars: tidied, protectedWords: protectedWords, writtenForms: writtenForms, phraseMatcher: phraseMatcher)
            .findSwaps()
        let swapped = swaps.isEmpty ? removed : SpanRewriter.apply(swaps, to: tidied, stage: Self.stageName)
        guard !removed.edits.isEmpty || !swaps.isEmpty else { return removed }
        // The swap edits are positioned in the text the removals left; report them against the original.
        let origin = Self.originalOffsets(of: scan.spans, count: chars.count)
        func inOriginal(_ edits: [EditOp], through map: [Int]) -> [EditOp] {
            edits.map { edit -> EditOp in
                var edit = edit
                edit.position = edit.position < map.count ? map[edit.position] : chars.count
                return edit
            }
        }
        let swapMap =
            swaps.isEmpty
            ? origin
            : Self.originalOffsets(of: swaps, count: tidied.count).map { $0 < origin.count ? origin[$0] : chars.count }
        var edits = removed.edits + (swaps.isEmpty ? [] : inOriginal(swapped.edits, through: origin))
        // A swap or a removal can leave the wrong "a" or "an" before the next word.
        let final = Array(swapped.text)
        let finalScan = Scan(chars: final, protectedWords: protectedWords, writtenForms: writtenForms, phraseMatcher: phraseMatcher)
        let known = Set(scan.articlePairs().map { "\($0.offset):\($0.key)" })
        let articles = finalScan.articleRepairs(skipping: known, origin: swapMap)
        guard !articles.isEmpty else { return StageResult(text: swapped.text, edits: edits) }
        let repaired = SpanRewriter.apply(articles, to: final, stage: Self.stageName)
        edits += inOriginal(repaired.edits, through: swapMap)
        return StageResult(text: repaired.text, edits: edits)
    }

    /// For each character of the text `SpanRewriter` produces from `spans`, where it sat in the original.
    private static func originalOffsets(of spans: [TextSpan], count: Int) -> [Int] {
        var map: [Int] = []
        var cursor = 0
        let ordered = spans.sorted { ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound) }
        for span in ordered {
            guard span.range.lowerBound >= cursor, span.cut.upperBound <= count,
                span.cut.lowerBound <= span.range.lowerBound, span.cut.upperBound >= span.range.upperBound
            else { continue }
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
        "crap": "junk", "bitching": "complaining", "ass": "butt", "asses": "butts",
    ]
    /// "fuck up", "fucked up", "fucking around" and so on.
    private static let messForms: [String: String] = ["fuck": "mess", "fucks": "messes", "fucked": "messed", "fucking": "messing"]
    private static let cheatForms: [String: String] = ["fuck": "cheat", "fucks": "cheats", "fucked": "cheated", "fucking": "cheating"]
    private static let sleepForms: [String: String] = [
        "fuck": "sleep with", "fucks": "sleeps with", "fucked": "slept with", "fucking": "sleeping with",
    ]
    private static let messUpForms: [String: String] = [
        "fuck": "mess up", "fucks": "messes up", "fucked": "messed up", "fucking": "messing up",
    ]
    private static let personObjects: Set<String> = ["her", "him", "them", "me", "us", "you"]
    /// What can sit between "fucked" and "over" in the cheating idiom ("fucked her over").
    private static let overObjects: Set<String> = personObjects.union(["it"])
    /// A time word after "over" makes it a preposition of time ("fucked her over the weekend").
    private static let overTimeWords: Set<String> = [
        "weekend", "weekends", "summer", "winter", "spring", "autumn", "fall", "week", "weeks", "month", "months", "year", "years",
        "day", "days", "night", "nights", "morning", "afternoon", "evening", "lunch", "dinner", "breakfast", "holiday", "holidays",
        "christmas", "easter", "thanksgiving", "break", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "decades", "decade", "century", "time", "hour", "hours", "minute", "minutes",
    ]
    private static let overDeterminers: Set<String> = ["the", "a", "an", "this", "that", "my", "our", "last", "next", "every", "one", "two", "three"]
    /// Acronyms said as a word, so "a" or "an" follows how the word sounds, not the first letter's name.
    private static let spokenAcronyms: [String: String] = [
        "nasa": "a", "nato": "a", "nafta": "a", "opec": "an", "unesco": "a", "unicef": "a", "fifa": "a", "scuba": "a",
        "laser": "a", "radar": "a", "sonar": "a", "gif": "a", "jpeg": "a", "ascii": "an", "osha": "an", "fema": "a",
        "darpa": "a", "nascar": "a", "taser": "a", "swat": "a",
    ]
    private static let talkVerbs: Set<String> = ["talk", "talks", "talked", "talking"]
    /// Words before a swear word that mark it as a verb ("I shit you not", "to bitch", "they bitch").
    private static let verbLeaders: Set<String> = [
        "i", "we", "they", "to", "will", "would", "can", "could", "should", "might", "must", "may", "shall", "not", "never",
        "don't", "doesn't", "didn't", "won't", "can't", "couldn't", "wouldn't", "shouldn't", "i'll", "we'll", "they'll",
        "you'll", "he'll", "she'll", "it'll", "i'd", "we'd", "they'd", "you'd", "he'd", "she'd",
    ]
    /// Words before a swear word that mark it as a noun ("a bitch", "of shit", "my shit", "two shits").
    private static let nounLeaders: Set<String> = [
        "a", "an", "the", "this", "that", "these", "those", "my", "your", "his", "her", "its", "our", "their", "some", "any",
        "no", "each", "every", "another", "such", "what", "whose", "many", "few", "several", "more", "most", "other", "of",
        "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten", "like", "you", "stupid",
    ]
    private static let idiomCounts: Set<String> = ["a", "one", "two", "three", "no", "any"]
    private static let giveVerbs: Set<String> = ["give", "gives", "gave", "giving", "given"]
    /// What "fuck" at the start of a sentence can be a dismissal of ("fuck the police").
    private static let forgetObjects: Set<String> = [
        "the", "those", "these", "my", "his", "her", "their", "our", "your", "him", "them", "everything", "everyone", "everybody",
    ]
    /// Words that can't be the object in "fucked X up".
    private static let phrasalStops: Set<String> = [
        "and", "or", "but", "to", "of", "in", "on", "at", "for", "with", "up", "around", "off", "out", "so", "if", "because",
    ]

    /// Whether "a" or "an" before this word should be "an": a vowel letter, except where it sounds like "y" or "w"
    /// ("university", "one"), plus the silent h of "hour" and "honest".
    static func startsWithVowelSound(_ word: String) -> Bool {
        let w = word.lowercased()
        if ["hour", "honest", "honor", "honour", "heir"].contains(where: { w.hasPrefix($0) }) { return true }
        guard let first = w.first, "aeiou".contains(first) else { return false }
        if ["eu", "once", "use", "usu", "uti", "uto", "ubiq", "unanim"].contains(where: { w.hasPrefix($0) }) { return false }
        if w.hasPrefix("one") { return w.hasPrefix("onerous") }
        if w.hasPrefix("uni") { return ["unim", "unin", "unid"].contains(where: { w.hasPrefix($0) }) }
        return true
    }
    /// Adjective forms dropped before the noun they modify.
    private static let droppedAdjectives: Set<String> = ["damned", "goddamned"]

    /// Part-of-speech tags for the characters of a text, computed only when an intensifier needs one.
    private final class LexicalClasses {
        private let text: String
        private let indices: [String.Index]
        private lazy var tagger: NLTagger = {
            let tagger = NLTagger(tagSchemes: [.lexicalClass])
            tagger.string = text
            // The cleanup is English. Left to detect the language itself, the tagger reads short sentences like "I drove a
            // goddamn car." as another language on some OS releases, and tags "a" as a preposition.
            tagger.setLanguage(.english, range: text.startIndex..<text.endIndex)
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

        init(chars: [Character], protectedWords: Set<String>, writtenForms: Set<String>, phraseMatcher: PhraseMatcher) {
            self.chars = chars
            self.n = chars.count
            let lower = TextScan.lowered(chars)
            self.words = TextScan.words(chars, lower)
            self.protectedWords = protectedWords
            self.writtenForms = writtenForms
            self.tags = LexicalClasses(chars)
            self.removed = [Bool](repeating: false, count: chars.count)
            var covered = [Bool](repeating: false, count: chars.count)
            // All hits of every phrase, so overlapping phrases ("oh my", "my damn project") all keep their cover.
            for hit in phraseMatcher.allMatches(chars, lower: lower) {
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
                words[k].start > words[k - 1].end
            else { return false }
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
                ["shit", "crap", "fuck"].contains(words[k + 1].lower)
            else { return nil }
            return k + 1
        }

        /// "Fuck you", "fuck off", "fuck that", "fuck it", "fuck me", "screw you": a dismissal that can go whole. "that" and "this"
        /// only when nothing follows; with an object they become "Forget ..." (see `findSwaps`). "it" may also be
        /// followed by a new clause ("Fuck it let's go").
        func dismissiveEnd(from k: Int) -> Int? {
            let verb = words[k].lower
            guard verb == "fuck" || verb == "screw", isFree(k), adjacent(k), isFree(k + 1) else { return nil }
            let target = words[k + 1].lower
            guard ["you", "yourself", "off", "that", "this", "it", "me"].contains(target) else { return nil }
            if verb == "screw" || target == "me" {
                var j = words[k].start - 1
                while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
                guard sentenceStart(before: words[k].start) || (j >= 0 && chars[j] == ",") else { return nil }
            }
            let after = words[k + 1].end
            if after >= n || isPunctuation(chars[after]) || isClauseEnd(after) { return k + 1 }
            if target == "it", sentenceStart(before: words[k].start), adjacent(k + 1), k + 2 < words.count,
                startsClause(at: k + 2) || ["i", "we", "they", "he", "she"].contains(words[k + 2].lower)
            {
                return k + 1
            }
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
                let b = tags.lexicalClass(at: words[k + 1].start), b == .verb
            else { return false }
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

        /// The word before `k`, when only spaces sit between them, with typographic apostrophes straightened.
        func previous(_ k: Int) -> String? {
            guard k > 0, adjacent(k - 1) else { return nil }
            return words[k - 1].lower.replacingOccurrences(of: "\u{2019}", with: "'")
        }

        /// Whether a verb form of the swear word at `k` fits here: after a subject, "to" or an auxiliary. A determiner,
        /// possessive, number or "of" before it means a noun. The tagger only breaks the tie for -s forms, since it
        /// misreads the swear words themselves.
        func isVerbPosition(_ k: Int, thirdPerson: Bool) -> Bool {
            guard let prev = previous(k) else { return false }
            // "you" is a subject before a verb ("You bitch about work") and a noun phrase opener in a vocative ("You bitch!").
            if prev == "you" { return !thirdPerson && adjacent(k) }
            if ProfanityRemover.verbLeaders.contains(prev) { return true }
            if ProfanityRemover.nounLeaders.contains(prev) { return false }
            guard thirdPerson else { return false }
            switch tags.lexicalClass(at: words[k - 1].start) {
            case .some(.noun), .some(.pronoun): return true
            default: return false
            }
        }

        /// "give a shit", "gave two fucks": the noun is part of an idiom for caring.
        func isGiveIdiom(_ k: Int) -> Bool {
            guard let prev = previous(k), ProfanityRemover.idiomCounts.contains(prev), k > 1, adjacent(k - 2) else { return false }
            return ProfanityRemover.giveVerbs.contains(words[k - 2].lower)
        }

        /// "fuck this", "fuck the police": a dismissal with an object, at the start of a sentence or clause.
        func isForgetObject(_ k: Int) -> Bool {
            guard adjacent(k), isFree(k + 1), ProfanityRemover.forgetObjects.contains(words[k + 1].lower) || isName(k + 1) else { return false }
            return previous(k) == nil
        }

        /// A capitalised word that isn't "I": a person's name, as far as spoken text can tell.
        func isName(_ k: Int) -> Bool {
            k < words.count && words[k].lower != "i" && chars[words[k].start].isUppercase && !isAcronym(words[k])
        }

        /// "fucked her over the weekend": the idiom needs a pronoun between the verb and "over", and no time word after.
        func isCheatingOver(_ k: Int, _ over: Int) -> Bool {
            guard over == k + 2, ProfanityRemover.overObjects.contains(words[k + 1].lower) else { return false }
            var after = over + 1
            while after < words.count, adjacent(after - 1), ProfanityRemover.overDeterminers.contains(words[after].lower) { after += 1 }
            guard after < words.count, adjacent(after - 1) else { return true }
            return !ProfanityRemover.overTimeWords.contains(words[after].lower)
        }

        func isAcronym(_ w: ScanWord) -> Bool {
            w.end - w.start > 1 && chars[w.start..<w.end].allSatisfy { $0.isUppercase }
        }

        /// "fucked it up", "fuck the whole thing up": the object sits between the verb and "up".
        func hasSplitUp(_ k: Int) -> Bool { splitParticle(k, "up") != nil }

        /// The particle that sits one to three words after the verb at `k` ("fucked us over"), when nothing in between
        /// ends the phrase.
        func splitParticle(_ k: Int, _ particle: String) -> Int? {
            for length in 1...3 {
                let at = k + length + 1
                guard at < words.count, (k...(at - 1)).allSatisfy({ adjacent($0) }) else { return nil }
                if (k + 1...k + length).contains(where: { ProfanityRemover.phrasalStops.contains(words[$0].lower) }) { return nil }
                if words[at].lower == particle, isFree(at) { return at }
            }
            return nil
        }

        /// Mild stand-ins for the swearing that is still in the text after the removals.
        func findSwaps() -> [TextSpan] {
            var spans: [TextSpan] = []
            // Words that must come out capitalised because the dropped word before them opened the sentence.
            var capitalise: Set<Int> = []
            var handled: Set<Int> = []
            func cased(_ k: Int, _ text: String) -> String {
                var text = matchingCase(text, like: words[k])
                if capitalise.contains(k), let first = text.first { text = first.uppercased() + text.dropFirst() }
                return text
            }
            func replace(_ k: Int, _ with: String, through end: Int? = nil) {
                let stop = end ?? words[k].end
                spans.append(TextSpan(range: words[k].start..<stop, replacement: cased(k, with)))
                handled.insert(k)
            }
            /// Drops the word and the space after it, or the space before it at the end of a clause.
            func drop(_ k: Int) {
                let w = words[k]
                if adjacent(k) {
                    spans.append(TextSpan(range: w.start..<w.end, cut: w.start..<words[k + 1].start, replacement: ""))
                    if capitalise.contains(k) || sentenceStart(before: w.start), !keepsCase(words[k + 1]) { capitalise.insert(k + 1) }
                } else {
                    var back = w.start
                    while back > 0, TextScan.isSpace(chars[back - 1]) { back -= 1 }
                    spans.append(TextSpan(range: w.start..<w.end, cut: back..<w.end, replacement: ""))
                }
                handled.insert(k)
            }
            func nextIs(_ k: Int, _ options: Set<String>) -> Bool {
                adjacent(k) && options.contains(words[k + 1].lower) && isFree(k + 1)
            }
            var k = 0
            while k < words.count {
                let lower = words[k].lower
                if lower == "pissed", isFree(k), nextIs(k, ["off"]) {
                    spans.append(TextSpan(range: words[k].start..<words[k + 1].end, replacement: matchingCase("annoyed", like: words[k])))
                    handled.insert(k)
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
                if let mess = ProfanityRemover.messForms[lower], nextIs(k, ["up", "around", "with"]) || hasSplitUp(k) {
                    replace(k, mess)
                } else if lower == "fuck", nextIs(k, ["this", "that"]), adjacent(k + 1) {
                    replace(k, "forget")
                } else if lower == "ass", k >= 3, adjacent(k - 1), adjacent(k - 2), adjacent(k - 3),
                    words[k - 1].lower == "the", words[k - 2].lower == "in", words[k - 3].lower == "pain"
                {
                    replace(k, "neck")
                } else if ProfanityRemover.droppedAdjectives.contains(lower), adjacent(k), modifiesNext(k) {
                    // Only the adjective goes; the noun after it still gets its own swap ("damned asshole" is "jerk").
                    drop(k)
                } else if lower == "shit" || lower == "shits" || lower == "shitting" {
                    if lower == "shitting" {
                        replace(k, "dumping")
                    } else if isGiveIdiom(k) {
                        replace(k, lower == "shit" ? "hoot" : "hoots")
                    } else if lower == "shit", adjacent(k), words[k + 1].lower == "you", adjacent(k + 1), words[k + 2].lower == "not" {
                        replace(k, "kid")
                    } else if isVerbPosition(k, thirdPerson: lower == "shits") {
                        replace(k, lower == "shit" ? "dump" : "dumps")
                    } else if lower == "shits", previous(k) != nil, !ProfanityRemover.nounLeaders.contains(previous(k) ?? "") {
                        replace(k, "dumps")
                    } else if lower == "shits" {
                        replace(k, "stuff")
                    } else if k > 0, adjacent(k - 1), ProfanityRemover.talkVerbs.contains(words[k - 1].lower) {
                        replace(k, "nonsense")
                    } else if k > 1, adjacent(k - 1), adjacent(k - 2), words[k - 1].lower == "of", words[k - 2].lower == "piece" {
                        replace(k, "junk")
                    } else {
                        replace(k, "stuff")
                    }
                } else if lower == "bitch" || lower == "bitches" {
                    if isVerbPosition(k, thirdPerson: lower == "bitches") {
                        replace(k, lower == "bitch" ? "complain" : "complains")
                    } else {
                        replace(k, lower == "bitch" ? "jerk" : "jerks")
                    }
                } else if lower == "bitched" {
                    replace(k, "complained")
                } else if lower == "bitchin" {
                    let end = words[k].end < n && "'\u{2019}".contains(chars[words[k].end]) ? words[k].end + 1 : words[k].end
                    // The verb ("stop bitchin'", "he bitchin' about it") complains; only the adjective is great.
                    let prev = previous(k) ?? ""
                    let aboutNext = k + 1 < words.count && TextScan.onlySpaces(chars, end, words[k + 1].start) && words[k + 1].lower == "about"
                    let isVerb =
                        aboutNext || ProfanityRemover.gerundTriggers.contains(prev)
                        || ["i", "we", "they", "you", "he", "she"].contains(prev)
                    replace(k, isVerb ? "complaining" : "great", through: end)
                } else if lower == "fuck" || lower == "fucks" || lower == "fucked" || lower == "fucking" || lower == "motherfucking" {
                    if lower == "motherfucking" {
                        drop(k)
                    } else if lower == "fuck" || lower == "fucks", isGiveIdiom(k) {
                        replace(k, lower == "fuck" ? "hoot" : "hoots")
                    } else if lower == "fuck", isForgetObject(k) {
                        replace(k, "forget")
                    } else if let cheat = ProfanityRemover.cheatForms[lower], nextIs(k, ["over"]) {
                        replace(k, cheat, through: words[k + 1].end)
                    } else if let cheat = ProfanityRemover.cheatForms[lower], let over = splitParticle(k, "over"), isCheatingOver(k, over) {
                        replace(k, cheat)
                        spans.append(TextSpan(range: words[over].start..<words[over].end, cut: words[over - 1].end..<words[over].end, replacement: ""))
                    } else if let sleep = ProfanityRemover.sleepForms[lower], adjacent(k), isFree(k + 1),
                        ProfanityRemover.personObjects.contains(words[k + 1].lower)
                    {
                        replace(k, sleep)
                    } else if let mess = ProfanityRemover.messUpForms[lower] {
                        replace(k, mess)
                    }
                } else if let mild = ProfanityRemover.swaps[lower] {
                    replace(k, mild)
                }
            }
            for index in capitalise where !handled.contains(index) {
                if !keepsCase(words[index]), let up = TextScan.capitalized(chars, words[index]) {
                    spans.append(TextSpan(range: words[index].start..<words[index].end, replacement: up))
                }
            }
            return spans
        }

        // MARK: Articles

        /// Each "a" or "an" with the word right after it, keyed by the pair in lower case.
        func articlePairs() -> [(key: String, article: Int, offset: Int)] {
            var pairs: [(key: String, article: Int, offset: Int)] = []
            for k in 0..<max(words.count - 1, 0) where ["a", "an"].contains(words[k].lower) && adjacent(k) && !insideToken(words[k]) {
                pairs.append((words[k].lower + " " + words[k + 1].lower, k, words[k].start))
            }
            return pairs
        }

        /// Fixes "a" and "an" before the word that follows, except for pairs already in the text before the edits
        /// (`skipping`, "original offset:pair"), which were the speaker's. `origin` maps this text's offsets back to the
        /// original. Capitalisation is kept.
        func articleRepairs(skipping known: Set<String>, origin: [Int]) -> [TextSpan] {
            var spans: [TextSpan] = []
            for (key, k, offset) in articlePairs() {
                let original = offset < origin.count ? origin[offset] : n
                if known.contains("\(original):\(key)") { continue }
                let next = words[k + 1]
                guard isFree(k), isFree(k + 1), let first = chars[next.start...].first, first.isLetter else { continue }
                // An acronym ("an MBA", "a UFO") is read letter by letter, so the letter's name decides, unless it's said as a word ("a NASA").
                let wanted =
                    isAcronym(next)
                    ? (ProfanityRemover.spokenAcronyms[next.lower] ?? ("AEFHILMNORSX".contains(chars[next.start]) ? "an" : "a"))
                    : (ProfanityRemover.startsWithVowelSound(next.lower) ? "an" : "a")
                guard wanted != words[k].lower else { continue }
                spans.append(TextSpan(range: words[k].start..<words[k].end, replacement: matchingCase(wanted, like: words[k])))
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
                    !nextUnitStarts.contains(next), !keepsCase(words[next]), let up = TextScan.capitalized(chars, words[next])
                {
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
