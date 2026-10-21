// Adapted from OpenWhispr (https://github.com/OpenWhispr/openwhispr, 5f9a88b), MIT License, Copyright (c) 2024 OpenWhispr Team.
import Foundation

/// A spelling fix the user made to dictated text: what Mouthtype wrote and what the user turned it into.
public struct CorrectionProposal: Sendable, Equatable, Hashable {
    public var heard: String
    public var corrected: String

    public init(heard: String, corrected: String) {
        self.heard = heard
        self.corrected = corrected
    }
}

public struct CorrectionAnalysis: Sendable, Equatable {
    /// Fixes worth offering to remember.
    public var proposals: [CorrectionProposal] = []
    /// Learned rules whose written form the user changed back to the heard form.
    public var reverted: [DictionaryRule] = []

    public init(proposals: [CorrectionProposal] = [], reverted: [DictionaryRule] = []) {
        self.proposals = proposals
        self.reverted = reverted
    }
}

/// Compares what Mouthtype pasted with what the field holds later and picks out the edits that look like vocabulary
/// fixes. Pure: the texts go in, a handful of word pairs come out, nothing is kept.
///
/// The dictated span is found inside the field text by a word-level fitting alignment (free start and end in the
/// field, so text typed before or after is skipped), then diffed against the pasted words by LCS. A gap between two
/// matched words that holds one to three words on each side is a candidate. Matching ignores case and the
/// punctuation around a word, so a capital or a comma alone is never a correction.
///
/// A candidate is kept when the two sides are close enough to be a spelling or hearing fix: the lowercased,
/// diacritic-folded, space-stripped forms are within a normalised edit distance of `maxDistanceRatio` (0.65), or have
/// the same Soundex code (first letter plus consonant classes) with at least three letters. A heard side made only
/// of common English words is kept only when the corrected side reads as a name or term (a capital the heard side
/// lacked, or a capital inside the word). The whole result is dropped when more than half the dictated words were
/// changed, which is rewriting rather than correcting.
public enum CorrectionLearner {
    public static let maxDistanceRatio = 0.65
    /// Longest squashed side `similar` will compare. Edit distance is quadratic, and no vocabulary fix is this long.
    static let maxSimilarLength = 64
    public static let maxPhraseWords = 3
    /// Largest alignment table (dictated words times field words) worth filling; a bigger field gives up.
    static let maxCells = 12_000_000
    /// A field longer than this is a document, not a message; reading it word by word isn't worth the wait.
    public static let maxFieldCharacters = 400_000

    public static func proposals(pasted: String, field: String) -> [CorrectionProposal] {
        analyse(pasted: pasted, field: field).proposals
    }

    /// `learned` are the rules Mouthtype itself added, so a change back to their heard form can be reported.
    public static func analyse(pasted: String, field: String, learned: [DictionaryRule] = []) -> CorrectionAnalysis {
        guard field.count <= maxFieldCharacters else { return CorrectionAnalysis() }
        let original = words(in: pasted)
        guard original.count >= 2 else { return CorrectionAnalysis() }
        let fieldWords = words(in: field)
        guard !fieldWords.isEmpty, original.count * fieldWords.count <= maxCells else { return CorrectionAnalysis() }
        guard let window = locate(original, in: fieldWords) else { return CorrectionAnalysis() }
        let edited = Array(fieldWords[window])

        let gaps = differences(original, edited)
        let changed = gaps.reduce(0) { $0 + $1.original.count }
        guard Double(changed) <= Double(original.count) * 0.5 else { return CorrectionAnalysis() }

        var result = CorrectionAnalysis()
        var seen = Set<String>()
        for gap in gaps where !gap.original.isEmpty && !gap.edited.isEmpty {
            let before = gap.original.map(\.surface).joined(separator: " ")
            let after = gap.edited.map(\.surface).joined(separator: " ")
            let beforeKey = gap.original.map(\.key).joined(separator: " ")
            let afterKey = gap.edited.map(\.key).joined(separator: " ")
            if let rule = learned.first(where: { normalise($0.written) == beforeKey && normalise($0.heard) == afterKey }) {
                if !result.reverted.contains(rule) { result.reverted.append(rule) }
                continue
            }
            guard looksLikeVocabularyFix(heard: before, corrected: after, heardWords: gap.original.count, correctedWords: gap.edited.count),
                  seen.insert(beforeKey + "\u{1F}" + afterKey).inserted else { continue }
            result.proposals.append(CorrectionProposal(heard: before, corrected: after))
        }
        return result
    }

    // MARK: Words

    struct Word: Equatable {
        var surface: String
        var key: String
    }

    static func words(in text: String) -> [Word] {
        text.split(whereSeparator: \.isWhitespace).compactMap { piece in
            let trimmed = Substring(piece).drop(while: { !TextScan.isWordChar($0) }).reversed().drop(while: { !TextScan.isWordChar($0) }).reversed()
            guard !trimmed.isEmpty else { return nil }
            let surface = String(trimmed)
            return Word(surface: surface, key: normalise(surface))
        }
    }

    static func normalise(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
            .split(whereSeparator: \.isWhitespace).map { piece in
                String(Substring(piece).drop(while: { !TextScan.isWordChar($0) }).reversed().drop(while: { !TextScan.isWordChar($0) }).reversed())
            }.filter { !$0.isEmpty }.joined(separator: " ")
    }

    // MARK: Locating the span

    /// The stretch of `field` that best lines up with `original`: the fitting alignment with the fewest word edits,
    /// preferring the longer stretch on a tie so an edited word at either end stays inside it.
    static func locate(_ original: [Word], in field: [Word]) -> Range<Int>? {
        var ids: [String: Int32] = [:]
        func id(_ key: String) -> Int32 {
            if let known = ids[key] { return known }
            let next = Int32(ids.count)
            ids[key] = next
            return next
        }
        let a = original.map { id($0.key) }
        let b = field.map { id($0.key) }
        let n = a.count, m = b.count

        var cost = [Int32](repeating: 0, count: m + 1)
        var start = (0...m).map(Int32.init)
        var nextCost = cost, nextStart = start
        for i in 1...n {
            nextCost[0] = Int32(i)
            nextStart[0] = 0
            for j in 1...m {
                var best = cost[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                var from = start[j - 1]
                let up = cost[j] + 1
                if up < best || (up == best && start[j] < from) { best = up; from = start[j] }
                let left = nextCost[j - 1] + 1
                if left < best || (left == best && nextStart[j - 1] < from) { best = left; from = nextStart[j - 1] }
                nextCost[j] = best
                nextStart[j] = from
            }
            swap(&cost, &nextCost)
            swap(&start, &nextStart)
        }
        var bestEnd = 0
        for j in 1...m {
            let better = cost[j] < cost[bestEnd]
                || (cost[j] == cost[bestEnd] && j - Int(start[j]) > bestEnd - Int(start[bestEnd]))
            if better { bestEnd = j }
        }
        guard bestEnd > 0 else { return nil }
        let range = Int(start[bestEnd])..<bestEnd
        guard !range.isEmpty else { return nil }
        return range
    }

    // MARK: Diff

    struct Gap {
        var original: [Word]
        var edited: [Word]
    }

    /// What lies between the words the two sides share, found by LCS over the lowercased words.
    static func differences(_ original: [Word], _ edited: [Word]) -> [Gap] {
        let n = original.count, m = edited.count
        var table = [[Int]](repeating: [Int](repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                table[i][j] = original[i].key == edited[j].key ? table[i + 1][j + 1] + 1 : max(table[i + 1][j], table[i][j + 1])
            }
        }
        var gaps: [Gap] = []
        var i = 0, j = 0
        var gapStartI = 0, gapStartJ = 0
        func close(_ endI: Int, _ endJ: Int) {
            if endI > gapStartI || endJ > gapStartJ {
                gaps.append(Gap(original: Array(original[gapStartI..<endI]), edited: Array(edited[gapStartJ..<endJ])))
            }
        }
        while i < n && j < m {
            if original[i].key == edited[j].key {
                close(i, j)
                i += 1
                j += 1
                gapStartI = i
                gapStartJ = j
            } else if table[i + 1][j] >= table[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        close(n, m)
        return gaps
    }

    // MARK: Filters

    static func looksLikeVocabularyFix(heard: String, corrected: String, heardWords: Int, correctedWords: Int) -> Bool {
        guard (1...maxPhraseWords).contains(heardWords), (1...maxPhraseWords).contains(correctedWords) else { return false }
        guard heard.lowercased() != corrected.lowercased() else { return false }
        guard letterCount(heard) >= 1, letterCount(corrected) >= 2 else { return false }
        guard similar(heard, corrected) else { return false }
        if isCommon(heard) && !looksLikeTerm(corrected, comparedTo: heard) { return false }
        return true
    }

    private static func letterCount(_ text: String) -> Int { text.filter(\.isLetter).count }

    /// Every word of the heard side is an everyday English word.
    private static func isCommon(_ phrase: String) -> Bool {
        phrase.split(separator: " ").allSatisfy { CommonWords.set.contains($0.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")) }
    }

    /// A capital the heard side didn't have, or a capital inside the word: a name or a product, not a sentence start.
    private static func looksLikeTerm(_ corrected: String, comparedTo heard: String) -> Bool {
        if corrected.dropFirst().contains(where: \.isUppercase) { return true }
        return corrected.first?.isUppercase == true && heard.first?.isUppercase != true
    }

    static func similar(_ a: String, _ b: String) -> Bool {
        let left = squash(a), right = squash(b)
        guard !left.isEmpty, !right.isEmpty else { return false }
        guard left.count <= maxSimilarLength, right.count <= maxSimilarLength else { return false }
        let ratio = Double(TextMetrics.editDistance(left, right)) / Double(max(left.count, right.count))
        if ratio <= maxDistanceRatio { return true }
        return left.count >= 3 && right.count >= 3 && soundex(left) == soundex(right) && soundex(left) != nil
    }

    private static func squash(_ text: String) -> [Character] {
        Array(text.lowercased().folding(options: .diacriticInsensitive, locale: nil).filter { $0.isLetter || $0.isNumber })
    }

    /// The classic Soundex code of a lowercase word, nil when it doesn't start with a letter.
    static func soundex(_ word: [Character]) -> String? {
        func code(_ c: Character) -> Character? {
            switch c {
            case "b", "f", "p", "v": "1"
            case "c", "g", "j", "k", "q", "s", "x", "z": "2"
            case "d", "t": "3"
            case "l": "4"
            case "m", "n": "5"
            case "r": "6"
            default: nil
            }
        }
        guard let first = word.first, first.isLetter else { return nil }
        var result = String(first.uppercased())
        var last = code(first)
        for c in word.dropFirst() {
            let current = code(c)
            if let current, current != last { result.append(current) }
            if c != "h" && c != "w" { last = current }
            if result.count == 4 { break }
        }
        return result.padding(toLength: 4, withPad: "0", startingAt: 0)
    }
}
