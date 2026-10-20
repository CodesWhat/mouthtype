import Foundation

/// One dictation from the log, reduced to what the suggester reads.
public struct SuggestionTake: Sendable, Equatable {
    public var id: String
    public var rawText: String
    public var finalText: String
    public var boostTermsApplied: [String]
    public var app: String?
    public var date: Date

    public init(id: String, rawText: String, finalText: String, boostTermsApplied: [String] = [], app: String? = nil, date: Date = Date(timeIntervalSince1970: 0)) {
        self.id = id
        self.rawText = rawText
        self.finalText = finalText
        self.boostTermsApplied = boostTermsApplied
        self.app = app
        self.date = date
    }
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

    public static func suggest(
        takes: [SuggestionTake],
        rules: [DictionaryRule],
        corrections: [CorrectionProposal] = [],
        limit: Int = defaultLimit
    ) -> [SpellingSuggestion] {
        var run = Run(takes: takes, rules: rules, corrections: corrections)
        return run.execute(limit: limit)
    }
}

// MARK: - Implementation

private struct Word {
    var text: String
    var lower: String
    var startsSentence: Bool
    var isAlpha: Bool
}

private func tokenize(_ s: String) -> [Word] {
    var words: [Word] = []
    var cur = ""
    var startsSentence = true
    func flush() {
        let trimmed = cur.trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        cur = ""
        guard !trimmed.isEmpty else { return }
        words.append(Word(text: trimmed, lower: trimmed.lowercased(), startsSentence: startsSentence, isAlpha: trimmed.allSatisfy(\.isLetter)))
        startsSentence = false
    }
    for ch in s {
        if ch.isLetter || ch.isNumber || ch == "'" {
            cur.append(ch)
        } else if ch == "\u{2019}" {
            cur.append("'")
        } else {
            flush()
            if ch == "." || ch == "!" || ch == "?" || ch == "\n" { startsSentence = true }
        }
    }
    flush()
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
}

private struct FormEntry {
    var count = 0
    var confidence = 0.0
    var evidence: [SuggestionEvidence] = []
}

private struct Group {
    var written: String
    var kind: SuggestionKind
    var forms: [String: FormEntry] = [:]
}

private struct Run {
    let takes: [SuggestionTake]
    let rules: [DictionaryRule]
    let corrections: [CorrectionProposal]

    var rawWords: [[Word]] = []
    var finalWords: [[Word]] = []
    var groups: [String: Group] = [:]

    init(takes: [SuggestionTake], rules: [DictionaryRule], corrections: [CorrectionProposal]) {
        self.takes = takes
        self.rules = rules
        self.corrections = corrections
    }

    // MARK: Helpers

    static func norm(_ s: String) -> String {
        tokenize(s).map(\.lower).joined(separator: " ")
    }

    static func sightingConfidence(_ n: Int) -> Double {
        n >= 3 ? 0.85 : (n == 2 ? 0.7 : 0.4)
    }

    func fragment(take: Int, word: Int, length: Int, final: Bool = false) -> String {
        let words = final ? finalWords[take] : rawWords[take]
        let lo = max(0, word - 2), hi = min(words.count - 1, word + length - 1 + 2)
        return words[lo...hi].map(\.text).joined(separator: " ")
    }

    func evidence(_ hits: Hits) -> [SuggestionEvidence] {
        hits.positions.map { SuggestionEvidence(takeID: takes[$0.take].id, fragment: fragment(take: $0.take, word: $0.word, length: $0.length)) }
    }

    mutating func add(kind: SuggestionKind, written: String, heard: String, count: Int, confidence: Double, evidence: [SuggestionEvidence]) {
        let key = "\(kind.rawValue)|\(written.lowercased())"
        var group = groups[key] ?? Group(written: written, kind: kind)
        var entry = group.forms[heard] ?? FormEntry()
        entry.count += count
        entry.confidence = max(entry.confidence, confidence)
        for e in evidence where entry.evidence.count < 3 && !entry.evidence.contains(e) { entry.evidence.append(e) }
        group.forms[heard] = entry
        groups[key] = group
    }

    // MARK: Pipeline

    mutating func execute(limit: Int) -> [SpellingSuggestion] {
        guard limit > 0 else { return [] }
        rawWords = takes.map { tokenize($0.rawText) }
        finalWords = takes.map { tokenize($0.finalText) }

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
        let heardPhrases = Set(rules.map { Self.norm($0.heard) }.filter { $0.contains(" ") })
        let heardLengths = Set(heardPhrases.map { $0.split(separator: " ").count })
        let phraseLengths = Set([2, 3]).union(heardLengths).filter { $0 <= 6 }.sorted()
        var minCompact = Int.max, maxCompact = 0
        for t in targets where t.compact.count >= 6 { minCompact = min(minCompact, t.compact.count); maxCompact = max(maxCompact, t.compact.count) }
        // Brand tokens the finals keep using (CodesWhat, GitHub) are joined-compound targets too.
        var finalForms: [String: [String: Int]] = [:]
        for words in finalWords {
            for w in words where w.text.count >= 3 && w.text.allSatisfy(\.isLetter) {
                if w.text == w.lower { finalLowerCount[w.lower, default: 0] += 1; continue }
                let capitalOnlyAtStart = w.startsSentence && w.text == w.lower.capitalized
                if capitalOnlyAtStart { continue }
                finalForms[w.lower, default: [:]][w.text, default: 0] += 1
            }
        }
        for (lower, forms) in finalForms {
            guard let (form, _) = forms.max(by: { $0.value < $1.value }) else { continue }
            let hasInnerCapital = form.dropFirst().contains(where: \.isUppercase) && form != form.uppercased()
            if hasInnerCapital, forms.values.reduce(0, +) >= 2, lower.count >= 6, !savedWritten.contains(form.lowercased()), seenTargets.insert(lower).inserted {
                targets.append(Target(written: form, compact: lower, classKey: PhoneticKey.classKey(lower), singleToken: true, fromRule: false))
                minCompact = min(minCompact, lower.count); maxCompact = max(maxCompact, lower.count)
            }
        }

        for (ti, words) in rawWords.enumerated() {
            for (wi, w) in words.enumerated() {
                let capMid = !w.startsSentence && w.text != w.lower && w.text.first?.isUppercase == true
                if w.text == w.lower { rawLowerCount[w.lower, default: 0] += 1 }
                unigrams[w.lower, default: Hits()].add(Position(take: ti, word: wi, length: 1), capitalizedMid: capMid)
            }
            for n in phraseLengths where words.count >= n {
                for wi in 0...(words.count - n) {
                    let slice = words[wi..<(wi + n)]
                    var joinable = false
                    if n <= 3, maxCompact > 0 {
                        let len = slice.reduce(0) { $0 + $1.lower.utf8.count }
                        joinable = len >= minCompact - 2 && len <= maxCompact + 2 && slice.allSatisfy { $0.isAlpha }
                    }
                    guard joinable || heardLengths.contains(n) else { continue }
                    let phrase = slice.map(\.lower).joined(separator: " ")
                    if joinable || heardPhrases.contains(phrase) { phraseHits[phrase, default: Hits()].add(Position(take: ti, word: wi, length: n)) }
                }
            }
        }

        misheardAndCasing(unigrams: unigrams, targets: targets, savedHeard: savedHeard, finalForms: finalForms)
        joined(phraseHits: phraseHits, targets: targets, savedHeard: savedHeard)
        fromCorrections(savedHeard: savedHeard)
        hazards(unigrams: unigrams, phraseHits: phraseHits)
        return ranked(limit: limit)
    }

    var finalLowerCount: [String: Int] = [:]
    var rawLowerCount: [String: Int] = [:]

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

        for (token, hits) in unigrams {
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
            guard let (target, ratio) = best else { continue }
            var conf = Self.sightingConfidence(hits.count)
            if ratio <= 0.5 { conf += 0.05 }
            if hits.capitalizedMid || (finalForms[token]?.values.contains { $0 > 0 }) == true { conf += 0.1 }
            let missedBoost = hits.positions.contains { p in
                takes[p.take].boostTermsApplied.contains { $0.caseInsensitiveCompare(target.written) == .orderedSame }
            }
            if missedBoost { conf += 0.05 }
            add(kind: .misheardVariant, written: target.written, heard: token, count: hits.count, confidence: min(conf, 0.95), evidence: evidence(hits))
        }

        // Casing: brand form from the dictionary first, then from what the finals consistently show.
        var brand: [String: (form: String, fromDictionary: Bool)] = [:]
        for rule in rules {
            let w = rule.written.trimmingCharacters(in: .whitespacesAndNewlines)
            guard w.count >= 3, w.allSatisfy(\.isLetter), w != w.lowercased() else { continue }
            brand[w.lowercased()] = (w, true)
        }
        for (lower, forms) in finalForms where brand[lower] == nil {
            let total = forms.values.reduce(0, +)
            guard total >= 1, let top = forms.max(by: { $0.value < $1.value }), Double(top.value) / Double(total) >= 0.6 else { continue }
            brand[lower] = (top.key, false)
        }
        for (lower, info) in brand {
            guard !savedHeard.contains(lower), !OrdinaryWords.isOrdinary(lower) else { continue }
            let rawLower = unigrams[lower].map { hits -> [Position] in
                hits.positions.filter { rawWords[$0.take][$0.word].text == lower }
            } ?? []
            let sightings = (rawLowerCount[lower] ?? 0) + (finalLowerCount[lower] ?? 0)
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
        for (phrase, hits) in phraseHits where phrase.contains(" ") && !savedHeard.contains(phrase) {
            let compact = phrase.replacingOccurrences(of: " ", with: "")
            var best: (Target, Int)?
            for t in usable where abs(t.compact.count - compact.count) <= 3 {
                let d = PhoneticKey.distance(compact, t.compact)
                let ratio = Double(d) / Double(max(compact.count, t.compact.count))
                let ok = d == 0 || (d == 1 && compact.count >= 7) || (ratio <= 0.4 && PhoneticKey.classKey(compact) == t.classKey)
                if ok, best == nil || d < best!.1 { best = (t, d) }
            }
            guard let (target, d) = best else { continue }
            var conf = Self.sightingConfidence(hits.count) + (d == 0 ? 0.1 : 0)
            if OrdinaryWords.isOrdinary(phrase) {
                guard d == 0 || (d <= 1 && compact.count >= 7) else { continue }
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
                  OrdinaryWords.warning(heard: heard, written: corrected) == nil, !OrdinaryWords.isOrdinary(heard) || heard.contains(" ") else { continue }
            let written = known[corrected.lowercased()] ?? corrected
            add(kind: .misheardVariant, written: written, heard: heard, count: 1, confidence: 0.7,
                evidence: [SuggestionEvidence(takeID: "correction", fragment: "\(c.heard) -> \(c.corrected)")])
        }
    }

    // MARK: 4: hazards

    mutating func hazards(unigrams: [String: Hits], phraseHits: [String: Hits]) {
        for rule in rules where !rule.starred {
            let heard = Self.norm(rule.heard)
            guard !heard.isEmpty, !rule.written.isEmpty else { continue }
            let hits = heard.contains(" ") ? phraseHits[heard] : unigrams[heard]
            let count = hits?.count ?? 0
            if OrdinaryWords.warning(for: rule) != nil {
                let ev = hits.map(evidence) ?? []
                add(kind: .removeHazard, written: rule.written, heard: rule.heard, count: count, confidence: min(0.75 + 0.04 * Double(count), 0.95), evidence: ev)
            } else if count == 0, takes.count >= SpellingSuggester.minTakesForUnusedHazard,
                      heard != rule.written.lowercased(), !rule.isJoinedSpelling {
                add(kind: .removeHazard, written: rule.written, heard: rule.heard, count: 0, confidence: 0.3, evidence: [])
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
            let confidence = min(1 - miss, 0.95)
            var ev: [SuggestionEvidence] = []
            for (_, e) in forms { for x in e.evidence where ev.count < 4 { ev.append(x) } }
            out.append(SpellingSuggestion(written: group.written, heardForms: forms.map(\.key), kind: group.kind, evidence: ev,
                                          count: forms.reduce(0) { $0 + $1.value.count }, confidence: (confidence * 100).rounded() / 100))
        }
        out.sort {
            if $0.confidence != $1.confidence { return $0.confidence > $1.confidence }
            if $0.count != $1.count { return $0.count > $1.count }
            return $0.id < $1.id
        }
        return Array(out.prefix(limit))
    }
}
