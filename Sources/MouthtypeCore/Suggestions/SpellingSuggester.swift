import Foundation

/// One dictation from the log, reduced to what the suggester reads.
public struct SuggestionTake: Sendable, Equatable {
    public var id: String
    public var rawText: String
    public var finalText: String
    public var boostTermsApplied: [String]
    public var app: String?
    public var date: Date
    /// The language the take was dictated in. Nil reads as English, so takes saved before 0.6.0 stay in.
    public var language: DictationLanguage?

    public init(
        id: String, rawText: String, finalText: String, boostTermsApplied: [String] = [], app: String? = nil,
        date: Date = Date(timeIntervalSince1970: 0), language: DictationLanguage? = nil
    ) {
        self.id = id
        self.rawText = rawText
        self.finalText = finalText
        self.boostTermsApplied = boostTermsApplied
        self.app = app
        self.date = date
        self.language = language
    }

    /// Suggestions are English only in 0.6.0: the phonetic key, the consonant rules and the known-word check all assume English.
    var isEnglish: Bool { language?.isEnglish ?? true }
}

public struct SuggestionEvidence: Sendable, Equatable, Hashable {
    public var takeID: String
    public var fragment: String

    public init(takeID: String, fragment: String) {
        self.takeID = takeID
        self.fragment = fragment
    }
}

public enum SuggestionKind: String, Sendable, Equatable, CaseIterable {
    case misheardVariant, casing, joinedCompound, removeHazard
}

/// For `.removeHazard`, `written` is the spelling the rule produces and `heardForms` holds the heard form to remove.
public struct SpellingSuggestion: Sendable, Equatable, Identifiable {
    public var written: String
    public var heardForms: [String]
    public var kind: SuggestionKind
    public var evidence: [SuggestionEvidence]
    public var count: Int
    public var confidence: Double
    /// For `.removeHazard`: the exact saved rules (heard and written as stored) this suggestion would remove.
    public var hazardRules: [DictionaryRule] = []

    public var id: String { "\(kind.rawValue)|\(written.lowercased())" }
}

/// Reads recent takes and the saved dictionary and proposes spelling rules worth saving, or saved ones worth dropping.
/// Pure and stateless: everything is rebuilt from the inputs, so the take log stays the only source of truth.
///
/// Four heuristics:
/// - misheard variants: a raw word that sounds like a saved written form (same folded Metaphone key, or a near typo)
///   and isn't an everyday word;
/// - casing: a word that shows up lowercase in raw or final text though the dictionary, or the finals, spell it with
///   a capital or brand casing;
/// - joined compounds: two or three adjacent raw words that run together into a saved written form or a brand token
///   the finals keep using (dry doc to Drydock, codes what to CodesWhat);
/// - hazards: a saved heard form that is an everyday word, or one that matched nothing in a long history.
public enum SpellingSuggester {
    public static let defaultLimit = 20
    /// Unused-rule hazards only mean something once the history is long enough to have used the rule.
    public static let minTakesForUnusedHazard = 100
    // `isKnownWord` takes a lowercase word and says whether it is ordinary English. The Mac app backs it with the
    // system spell checker; Core only knows the bundled list, so it stays AppKit-free.

    public static func suggest(
        takes: [SuggestionTake],
        rules: [DictionaryRule],
        corrections: [CorrectionProposal] = [],
        limit: Int = defaultLimit,
        isKnownWord: @escaping @Sendable (String) -> Bool = { OrdinaryWords.isOrdinary($0) }
    ) -> [SpellingSuggestion] {
        let takes = takes.filter(\.isEnglish)
        var run = Run(takes: takes, rules: rules, corrections: corrections, isKnownWord: isKnownWord)
        return run.execute(limit: limit)
    }
}

extension SpellingSuggester {
    static func boundedDistanceForTesting(_ a: String, _ b: String, limit: Int) -> Int? {
        Run.boundedDistance(Array(a.unicodeScalars), Array(b.unicodeScalars), limit: limit)
    }
}

// MARK: - Implementation

private struct Word {
    var text: String
    var lower: String
    var startsSentence: Bool
    var isAlpha: Bool
    /// Only whitespace separates this word from the one before it.
    var adjacentToPrevious: Bool
    var start: String.Index
    var end: String.Index
}

private func tokenize(_ s: String) -> [Word] {
    var words: [Word] = []
    var cur = ""
    var curStart = s.startIndex
    var startsSentence = true
    var punctuationSince = false
    func flush(end: String.Index) {
        let trimmed = cur.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let leadTrimmed = cur.hasPrefix("'"), trailTrimmed = cur.hasSuffix("'")
        cur = ""
        // Stripped boundary apostrophes are punctuation: they break compound adjacency like any other mark.
        guard !trimmed.isEmpty else {
            if leadTrimmed || trailTrimmed { punctuationSince = true }
            return
        }
        words.append(
            Word(
                text: trimmed, lower: trimmed.lowercased(), startsSentence: startsSentence, isAlpha: trimmed.allSatisfy(\.isLetter),
                adjacentToPrevious: !words.isEmpty && !punctuationSince && !leadTrimmed, start: curStart, end: end))
        startsSentence = false
        punctuationSince = trailTrimmed
    }
    for i in s.indices {
        let ch = s[i]
        if ch.isLetter || ch.isNumber || ch == "'" {
            if cur.isEmpty { curStart = i }
            cur.append(ch)
        } else if ch == "\u{2019}" {
            if cur.isEmpty { curStart = i }
            cur.append("'")
        } else {
            flush(end: i)
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { startsSentence = true }
            if !(ch == " " || ch == "\t") { punctuationSince = true }
        }
    }
    flush(end: s.endIndex)
    return words
}

private struct Position { var take: Int; var word: Int; var length: Int }

private struct Hits {
    var count = 0
    var positions: [Position] = []
    var capitalizedMid = false
    mutating func add(_ p: Position, capitalizedMid cap: Bool = false) {
        count += 1
        if positions.count < 3 { positions.append(p) }
        if cap { capitalizedMid = true }
    }
}

private struct Target {
    var written: String
    var compact: String
    var classKey: String
    var singleToken: Bool
    var fromRule: Bool
    let scalars: [Unicode.Scalar]

    init(written: String, compact: String, classKey: String, singleToken: Bool, fromRule: Bool) {
        self.written = written
        self.compact = compact
        self.classKey = classKey
        self.singleToken = singleToken
        self.fromRule = fromRule
        self.scalars = Array(compact.unicodeScalars)
    }
}

private struct FormEntry {
    var count = 0
    var confidence = 0.0
    var evidence: [SuggestionEvidence] = []
    /// True while every contribution came from a loose match (folded phonetic key only).
    var weak = true
}

private struct Group {
    var written: String
    var kind: SuggestionKind
    var forms: [String: FormEntry] = [:]
    var hazardRules: [DictionaryRule] = []
}

private struct Run {
    let takes: [SuggestionTake]
    let rules: [DictionaryRule]
    let corrections: [CorrectionProposal]
    let isKnownWord: @Sendable (String) -> Bool

    var rawWords: [[Word]] = []
    var finalWords: [[Word]] = []
    var groups: [String: Group] = [:]

    init(takes: [SuggestionTake], rules: [DictionaryRule], corrections: [CorrectionProposal], isKnownWord: @escaping @Sendable (String) -> Bool) {
        self.isKnownWord = isKnownWord
        self.takes = takes
        self.rules = rules
        self.corrections = corrections
    }

    // MARK: Helpers

    /// Most frequent spelling; ties go to the form with an inner capital, then the lexicographically smallest.
    static func topForm(_ forms: [String: Int]) -> String? {
        func inner(_ f: String) -> Bool { f.dropFirst().contains(where: \.isUppercase) }
        return forms.max { a, b in
            if a.value != b.value { return a.value < b.value }
            if inner(a.key) != inner(b.key) { return !inner(a.key) }
            return a.key > b.key
        }?.key
    }

    /// 0 or 1 when the sequences are equal or one insert, delete or substitution apart, otherwise nil. No allocation.
    static func withinOneEdit(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar]) -> Int? {
        let (n, m) = (a.count, b.count)
        if abs(n - m) > 1 { return nil }
        var i = 0
        while i < n, i < m, a[i] == b[i] { i += 1 }
        if i == n && i == m { return 0 }
        if n == m {
            var j = i + 1
            while j < n, a[j] == b[j] { j += 1 }
            return j == n ? 1 : nil
        }
        // lengths differ by one: skip one scalar of the longer and the rest must match
        let (long, short) = n > m ? (a, b) : (b, a)
        var k = i
        while k < short.count, long[k + 1] == short[k] { k += 1 }
        return k == short.count ? 1 : nil
    }

    /// Edit distance when it is at most `limit`, otherwise nil. Stops as soon as a whole row exceeds the limit.
    static func boundedDistance(_ a: [Unicode.Scalar], _ b: [Unicode.Scalar], limit: Int) -> Int? {
        if abs(a.count - b.count) > limit { return nil }
        if limit == 1 { return withinOneEdit(a, b) }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            var rowMin = i
            for j in 1...b.count {
                let above = row[j]
                let v = min(above + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                row[j] = v
                diagonal = above
                if v < rowMin { rowMin = v }
            }
            if rowMin > limit { return nil }
        }
        return row[b.count] <= limit ? row[b.count] : nil
    }

    func isKnown(_ word: String) -> Bool {
        OrdinaryWords.isOrdinary(word) || isKnownWord(word)
    }

    static func norm(_ s: String) -> String {
        tokenize(s).map(\.lower).joined(separator: " ")
    }

    static func sightingConfidence(_ n: Int) -> Double {
        n >= 3 ? 0.85 : (n == 2 ? 0.7 : 0.4)
    }

    func fragment(take: Int, word: Int, length: Int, final: Bool = false) -> String {
        let words = final ? finalWords[take] : rawWords[take]
        let lo = max(0, word - 2), hi = min(words.count - 1, word + length - 1 + 2)
        let source = final ? takes[take].finalText : takes[take].rawText
        return String(source[words[lo].start..<words[hi].end])
    }

    func evidence(_ hits: Hits) -> [SuggestionEvidence] {
        hits.positions.map { SuggestionEvidence(takeID: takes[$0.take].id, fragment: fragment(take: $0.take, word: $0.word, length: $0.length)) }
    }

    mutating func add(kind: SuggestionKind, written: String, heard: String, count: Int, confidence: Double, evidence: [SuggestionEvidence], weak: Bool = false, hazardRule: DictionaryRule? = nil) {
        let key = "\(kind.rawValue)|\(written.lowercased())"
        var group = groups[key] ?? Group(written: written, kind: kind)
        var entry = group.forms[heard] ?? FormEntry()
        entry.weak = group.forms[heard] == nil ? weak : (entry.weak && weak)
        entry.count += count
        entry.confidence = max(entry.confidence, confidence)
        for e in evidence where entry.evidence.count < 3 && !entry.evidence.contains(e) { entry.evidence.append(e) }
        group.forms[heard] = entry
        if let hazardRule, !group.hazardRules.contains(hazardRule) { group.hazardRules.append(hazardRule) }
        groups[key] = group
    }

    // MARK: Pipeline

    mutating func execute(limit: Int) -> [SpellingSuggestion] {
        guard limit > 0 else { return [] }
        rawWords.reserveCapacity(takes.count)
        finalWords.reserveCapacity(takes.count)
        for (i, take) in takes.enumerated() {
            if i & 63 == 0, Task.isCancelled { return [] }
            rawWords.append(tokenize(take.rawText))
            finalWords.append(tokenize(take.finalText))
        }

        let savedHeard = Set(rules.map { Self.norm($0.heard) }.filter { !$0.isEmpty })
        var targets: [Target] = []
        var seenTargets = Set<String>()
        for rule in rules {
            let written = rule.written.trimmingCharacters(in: .whitespacesAndNewlines)
            let compact = written.lowercased().filter(\.isLetter)
            guard compact.count >= 4, written.allSatisfy({ $0.isLetter || $0 == " " }), seenTargets.insert(written.lowercased()).inserted else { continue }
            targets.append(Target(written: written, compact: compact, classKey: PhoneticKey.classKey(compact), singleToken: !written.contains(" "), fromRule: true))
        }
        let savedWritten = Set(rules.map { $0.written.lowercased() })

        // One pass over the raw text: unigram counts, plus phrase hits for joined compounds and rule matching.
        var unigrams: [String: Hits] = [:]
        var phraseHits: [String: Hits] = [:]
        var usageHits: [String: Hits] = [:]
        // Count literal heard forms with the dictionary's matcher, including boundary apostrophes and separators.
        let usageForms = rules.map(\.heard).filter { !tokenize($0).isEmpty }
        let usageMatcher = PhraseMatcher(patterns: usageForms)
        let usageKeys = usageForms.map(PhraseKey.normalized)
        let usageLengths = usageForms.map { tokenize($0).count }
        let phraseLengths = [2, 3]
        var minCompact = Int.max, maxCompact = 0
        for t in targets where t.compact.count >= 6 { minCompact = min(minCompact, t.compact.count); maxCompact = max(maxCompact, t.compact.count) }
        // Brand tokens the finals keep using (CodesWhat, GitHub) are joined-compound targets too.
        var finalForms: [String: [String: Int]] = [:]
        for (ti, words) in finalWords.enumerated() {
            if ti & 63 == 0, Task.isCancelled { return [] }
            for w in words where w.text.count >= 3 && w.text.allSatisfy(\.isLetter) {
                if w.text == w.lower { lowerTakes[w.lower, default: []].insert(ti); continue }
                let capitalOnlyAtStart = w.startsSentence && w.text == w.lower.capitalized
                if capitalOnlyAtStart { continue }
                finalForms[w.lower, default: [:]][w.text, default: 0] += 1
            }
        }
        for (lower, forms) in finalForms {
            guard let form = Self.topForm(forms) else { continue }
            let hasInnerCapital = form.dropFirst().contains(where: \.isUppercase) && form != form.uppercased()
            if hasInnerCapital, forms.values.reduce(0, +) >= 2, lower.count >= 6, !savedWritten.contains(form.lowercased()), seenTargets.insert(lower).inserted {
                targets.append(Target(written: form, compact: lower, classKey: PhoneticKey.classKey(lower), singleToken: true, fromRule: false))
                minCompact = min(minCompact, lower.count); maxCompact = max(maxCompact, lower.count)
            }
        }

        for (ti, words) in rawWords.enumerated() {
            if ti & 63 == 0, Task.isCancelled { return [] }
            for (wi, w) in words.enumerated() {
                let capMid = !w.startsSentence && w.text != w.lower && w.text.first?.isUppercase == true
                if w.text == w.lower { lowerTakes[w.lower, default: []].insert(ti) }
                unigrams[w.lower, default: Hits()].add(Position(take: ti, word: wi, length: 1), capitalizedMid: capMid)
            }
            if maxCompact > 0 {
                for n in phraseLengths where words.count >= n {
                    for wi in 0...(words.count - n) {
                        let slice = words[wi..<(wi + n)]
                        guard slice.dropFirst().allSatisfy({ $0.adjacentToPrevious && !$0.startsSentence }) else { continue }
                        let len = slice.reduce(0) { $0 + $1.lower.utf8.count }
                        guard len >= minCompact - 2, len <= maxCompact + 2, slice.allSatisfy({ $0.isAlpha }) else { continue }
                        let phrase = slice.map(\.lower).joined(separator: " ")
                        phraseHits[phrase, default: Hits()].add(Position(take: ti, word: wi, length: n))
                    }
                }
            }
            if !usageMatcher.isEmpty, !words.isEmpty {
                let source = takes[ti].rawText
                let chars = Array(source)
                let indices = Array(source.indices)
                for match in usageMatcher.allMatches(chars, lower: TextScan.lowered(chars)) {
                    let start = indices[match.range.lowerBound]
                    var lo = 0, hi = words.count
                    while lo < hi {
                        let mid = lo + (hi - lo) / 2
                        if words[mid].end <= start { lo = mid + 1 } else { hi = mid }
                    }
                    let position = Position(take: ti, word: min(lo, words.count - 1), length: usageLengths[match.pattern])
                    usageHits[usageKeys[match.pattern], default: Hits()].add(position)
                }
            }
        }

        if Task.isCancelled { return [] }
        misheardAndCasing(unigrams: unigrams, targets: targets, savedHeard: savedHeard, finalForms: finalForms)
        if Task.isCancelled { return [] }
        joined(phraseHits: phraseHits, targets: targets, savedHeard: savedHeard)
        if Task.isCancelled { return [] }
        fromCorrections(savedHeard: savedHeard)
        hazards(usageHits: usageHits)
        if Task.isCancelled { return [] }
        return ranked(limit: limit)
    }

    /// Takes where a word shows up in lowercase, in raw or final text. A take counts once.
    var lowerTakes: [String: Set<Int>] = [:]

    // MARK: 1 and 2: misheard variants and casing

    mutating func misheardAndCasing(unigrams: [String: Hits], targets: [Target], savedHeard: Set<String>, finalForms: [String: [String: Int]]) {
        let singles = targets.filter { $0.singleToken && $0.fromRule }
        var byClass: [String: [Target]] = [:]
        var byInitial: [Character: [Target]] = [:]
        for t in singles {
            byClass[t.classKey, default: []].append(t)
            if let c = t.compact.first { byInitial[c, default: []].append(t) }
        }
        let writtenLower = Set(singles.map { $0.written.lowercased() })
        var keyCache: [String: String] = [:]
        let correctionPairs = Set(corrections.map { "\(Self.norm($0.heard))|\($0.corrected.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())" })

        var tick = 0
        for (token, hits) in unigrams {
            tick &+= 1
            if tick & 255 == 0, Task.isCancelled { return }
            guard token.count >= 4, token.allSatisfy(\.isLetter), !savedHeard.contains(token), !OrdinaryWords.isOrdinary(token) else { continue }
            if writtenLower.contains(token) { continue }
            let key = keyCache[token] ?? PhoneticKey.classKey(token)
            keyCache[token] = key
            var best: (Target, Double)?
            for t in byClass[key] ?? [] {
                let r = PhoneticKey.distanceRatio(token, t.compact)
                // Far-apart spellings still count when the sound matches, if the word reads as a name or repeats.
                if r <= 0.9, key.count >= 3, r <= 0.75 || hits.capitalizedMid || hits.count >= 2, best == nil || r < best!.1 { best = (t, r) }
            }
            if best == nil, let first = token.first {
                for t in byInitial[first] ?? [] where abs(t.compact.count - token.count) <= 2 {
                    let r = PhoneticKey.distanceRatio(token, t.compact)
                    if r <= 0.25, best == nil || r < best!.1 { best = (t, r) }
                }
            }
            guard let (target, ratio) = best, !isKnown(token) else { continue }
            let missedBoost = hits.positions.contains { p in
                takes[p.take].boostTermsApplied.contains { $0.caseInsensitiveCompare(target.written) == .orderedSame }
            }
            let corrected = correctionPairs.contains("\(token)|\(target.written.lowercased())")
            var conf = Self.sightingConfidence(hits.count)
            if ratio <= 0.5 { conf += 0.05 }
            if ratio <= 0.25 || missedBoost || corrected {
                if hits.capitalizedMid || (finalForms[token]?.values.contains { $0 > 0 }) == true { conf += 0.1 }
                if missedBoost { conf += 0.05 }
                add(kind: .misheardVariant, written: target.written, heard: token, count: hits.count, confidence: min(conf, 0.95), evidence: evidence(hits))
            } else {
                // Matched only through the folded key: look-alike names (Chopin, Shaven) land here, so stay low and need repeats.
                guard hits.count >= 2 else { continue }
                add(kind: .misheardVariant, written: target.written, heard: token, count: hits.count, confidence: min(conf, 0.5), evidence: evidence(hits), weak: true)
            }
        }

        // Casing: brand form from the dictionary first, then from what the finals consistently show.
        var brand: [String: (form: String, fromDictionary: Bool)] = [:]
        let savedExact = Set(rules.map { $0.written.trimmingCharacters(in: .whitespacesAndNewlines) })
        for rule in rules {
            let w = rule.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard w.count >= 3, w.allSatisfy(\.isLetter), w != w.lowercased() else { continue }
            brand[w.lowercased()] = (w, true)
        }
        for (lower, forms) in finalForms where brand[lower] == nil {
            let total = forms.values.reduce(0, +)
            guard total >= 1, let top = Self.topForm(forms), Double(forms[top] ?? 0) / Double(total) >= 0.6 else { continue }
            brand[lower] = (top, false)
        }
        for (lower, info) in brand {
            guard !savedHeard.contains(lower), !OrdinaryWords.isOrdinary(lower) else { continue }
            // Plain Title case on an ordinary word (candy to Candy) is a title or list item, not a spelling. Brand
            // casing with an inner capital and forms the dictionary already saves still go through.
            let innerCapital = info.form.dropFirst().contains(where: \.isUppercase)
            if !innerCapital, !info.fromDictionary || !savedExact.contains(info.form), isKnown(lower) { continue }
            let rawLower =
                unigrams[lower].map { hits -> [Position] in
                    hits.positions.filter { rawWords[$0.take][$0.word].text == lower }
                } ?? []
            let sightings = lowerTakes[lower]?.count ?? 0
            guard sightings >= 1 else { continue }
            var conf = Self.sightingConfidence(sightings) + (sightings == 1 ? 0.1 : 0)
            if info.fromDictionary { conf += 0.15 }
            let ev = rawLower.map { SuggestionEvidence(takeID: takes[$0.take].id, fragment: fragment(take: $0.take, word: $0.word, length: 1)) }
            add(kind: .casing, written: info.form, heard: lower, count: sightings, confidence: min(conf, 0.95), evidence: ev)
        }
    }

    // MARK: 3: joined compounds

    mutating func joined(phraseHits: [String: Hits], targets: [Target], savedHeard: Set<String>) {
        let usable = targets.filter { $0.compact.count >= 6 }
        guard !usable.isEmpty else { return }
        // Only targets within the edit-distance length bound are ever compared.
        var byLength: [Int: [Target]] = [:]
        var byClass: [String: [Target]] = [:]
        for t in usable {
            byLength[t.compact.count, default: []].append(t)
            byClass[t.classKey, default: []].append(t)
        }
        var tick = 0
        for (phrase, hits) in phraseHits where phrase.contains(" ") && !savedHeard.contains(phrase) {
            tick &+= 1
            if tick & 255 == 0, Task.isCancelled { return }
            let compact = phrase.replacingOccurrences(of: " ", with: "")
            var best: (Target, Int)?
            let phraseKey = PhoneticKey.classKey(compact)
            let phraseScalars = Array(compact.unicodeScalars)
            func consider(_ t: Target, limit: Int) {
                guard let d = Self.boundedDistance(phraseScalars, t.scalars, limit: limit) else { return }
                let ratio = Double(d) / Double(max(compact.count, t.compact.count))
                let ok = d == 0 || (d == 1 && compact.count >= 7) || (ratio <= 0.4 && phraseKey == t.classKey)
                if ok, best == nil || d < best!.1 { best = (t, d) }
            }
            // Same-sounding targets may differ by up to 40%; everything else only matters at zero or one edit,
            // which needs a length within 1.
            for t in byClass[phraseKey] ?? [] where abs(t.compact.count - compact.count) <= 3 {
                consider(t, limit: max(1, Int(0.4 * Double(max(compact.count, t.compact.count)))))
            }
            for len in max(0, compact.count - 1)...(compact.count + 1) {
                for t in byLength[len] ?? [] where t.classKey != phraseKey { consider(t, limit: 1) }
            }
            guard let (target, d) = best, d == 0 || !isKnown(compact) else { continue }
            var conf = Self.sightingConfidence(hits.count) + (d == 0 ? 0.1 : 0)
            if OrdinaryWords.isOrdinary(phrase) {
                guard d == 0 else { continue }
                conf = min(conf, 0.6)
            }
            add(kind: .joinedCompound, written: target.written, heard: phrase, count: hits.count, confidence: min(conf, 0.95), evidence: evidence(hits))
        }
    }

    // MARK: Corrections the store already has

    mutating func fromCorrections(savedHeard: Set<String>) {
        let known = Dictionary(rules.map { ($0.written.lowercased(), $0.written) }, uniquingKeysWith: { a, _ in a })
        for c in corrections {
            let heard = Self.norm(c.heard)
            let corrected = c.corrected.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !heard.isEmpty, !corrected.isEmpty, heard != corrected.lowercased(), !savedHeard.contains(heard),
                OrdinaryWords.warning(heard: heard, written: corrected) == nil, (!isKnown(heard) || heard.contains(" "))
            else { continue }
            let written = known[corrected.lowercased()] ?? corrected
            add(
                kind: .misheardVariant, written: written, heard: heard, count: 1, confidence: 0.7,
                evidence: [SuggestionEvidence(takeID: "correction", fragment: "\(c.heard) -> \(c.corrected)")])
        }
    }

    // MARK: 4: hazards

    mutating func hazards(usageHits: [String: Hits]) {
        for rule in rules where !rule.starred {
            let heard = Self.norm(rule.heard)
            guard !heard.isEmpty, !rule.written.isEmpty else { continue }
            let hits = usageHits[PhraseKey.normalized(rule.heard)]
            let count = hits?.count ?? 0
            if OrdinaryWords.warning(for: rule) != nil {
                let ev = hits.map(evidence) ?? []
                add(kind: .removeHazard, written: rule.written, heard: rule.heard, count: count, confidence: min(0.75 + 0.04 * Double(count), 0.95), evidence: ev, hazardRule: rule)
            } else if count == 0, takes.count >= SpellingSuggester.minTakesForUnusedHazard,
                heard != rule.written.lowercased(), !rule.isJoinedSpelling
            {
                add(kind: .removeHazard, written: rule.written, heard: rule.heard, count: 0, confidence: 0.3, evidence: [], hazardRule: rule)
            }
        }
    }

    // MARK: Ranking

    func ranked(limit: Int) -> [SpellingSuggestion] {
        var out: [SpellingSuggestion] = []
        for group in groups.values {
            let forms = group.forms.sorted { ($0.value.count, $1.key) > ($1.value.count, $0.key) }
            var miss = 1.0
            for (_, e) in forms { miss *= 1 - e.confidence }
            var confidence = min(1 - miss, 0.95)
            if forms.allSatisfy({ $0.value.weak }) { confidence = min(confidence, 0.5) }
            var ev: [SuggestionEvidence] = []
            for (_, e) in forms { for x in e.evidence where ev.count < 4 { ev.append(x) } }
            out.append(
                SpellingSuggestion(
                    written: group.written, heardForms: forms.map(\.key), kind: group.kind, evidence: ev,
                    count: forms.reduce(0) { $0 + $1.value.count }, confidence: (confidence * 100).rounded() / 100,
                    hazardRules: group.hazardRules))
        }
        out.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }
        return Array(out.prefix(limit))
    }
}
