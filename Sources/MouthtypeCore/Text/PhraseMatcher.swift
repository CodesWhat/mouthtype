import Foundation

/// One pass, left to right, whole-word, case-insensitive phrase matching shared by the dictionary and the
/// snippets.
///
/// Adapted from Parrot's DictionaryReplacer (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License,
/// Copyright (c) 2026 Humanitas Labs. Same rules, reimplemented over Characters instead of a regex so building
/// the matcher costs nothing per call:
/// - A match may not touch a letter, digit or underscore in any script on either side (so `api` leaves `rapid`
///   alone and `café` is one word); a decomposed `é` is one Character, so it is not a boundary.
/// - Whitespace inside a pattern matches any run of whitespace.
/// - Where several patterns match at the same place, the longest wins; the first listed wins a tie.
/// - Matches never overlap, and callers insert text after matching, so inserted text is never re-scanned.
struct PhraseMatcher: Sendable {
    struct Match: Equatable {
        var range: Range<Int>
        var pattern: Int
    }

    private struct Pattern: Sendable {
        var chars: [Character]
        var index: Int
    }

    private let buckets: [Character: [Pattern]]

    /// `patterns[i]` is reported as `Match.pattern == i`. Empty patterns and later case-insensitive duplicates
    /// never match.
    init(patterns: [String]) {
        var seen = Set<String>()
        var built: [Character: [Pattern]] = [:]
        for (index, raw) in patterns.enumerated() {
            let collapsed = PhraseKey.collapsed(raw)
            guard !collapsed.isEmpty else { continue }
            let chars = TextScan.lowered(Array(collapsed))
            guard seen.insert(String(chars)).inserted else { continue }
            built[chars[0], default: []].append(Pattern(chars: chars, index: index))
        }
        for key in built.keys {
            built[key]?.sort { a, b in
                a.chars.count != b.chars.count ? a.chars.count > b.chars.count : a.index < b.index
            }
        }
        self.buckets = built
    }

    var isEmpty: Bool { buckets.isEmpty }

    func matches(_ chars: [Character], lower: [Character]) -> [Match] {
        guard !buckets.isEmpty else { return [] }
        let n = chars.count
        var result: [Match] = []
        var i = 0
        while i < n {
            if i > 0, TextScan.isWordChar(chars[i - 1]) { i += 1; continue }
            guard let candidates = buckets[lower[i]] else { i += 1; continue }
            var hit: Match?
            for pattern in candidates {
                if let end = match(pattern.chars, in: chars, lower: lower, at: i) {
                    hit = Match(range: i..<end, pattern: pattern.index)
                    break
                }
            }
            if let hit {
                result.append(hit)
                i = hit.range.upperBound
            } else {
                i += 1
            }
        }
        return result
    }

    /// Every pattern's hits, not just the winning one: at each start every pattern in the first-character bucket is
    /// tried, so overlapping phrases ("oh my", "my damn project") all report. A pattern still never overlaps its own
    /// previous hit, exactly as if it had been matched on its own. For marking covered text, not for replacing.
    func allMatches(_ chars: [Character], lower: [Character]) -> [Match] {
        guard !buckets.isEmpty else { return [] }
        let n = chars.count
        var result: [Match] = []
        var freeFrom: [Int: Int] = [:]
        for i in 0..<n {
            if i > 0, TextScan.isWordChar(chars[i - 1]) { continue }
            guard let candidates = buckets[lower[i]] else { continue }
            for pattern in candidates where i >= (freeFrom[pattern.index] ?? 0) {
                if let end = match(pattern.chars, in: chars, lower: lower, at: i) {
                    result.append(Match(range: i..<end, pattern: pattern.index))
                    freeFrom[pattern.index] = end
                }
            }
        }
        return result
    }

    private func match(_ pattern: [Character], in chars: [Character], lower: [Character], at start: Int) -> Int? {
        let n = chars.count
        var j = start
        for pc in pattern {
            if pc == " " {
                guard j < n, chars[j].isWhitespace else { return nil }
                while j < n, chars[j].isWhitespace { j += 1 }
            } else {
                guard j < n, lower[j] == pc else { return nil }
                j += 1
            }
        }
        if j < n, TextScan.isWordChar(chars[j]) { return nil }
        return j
    }
}
