import Foundation
import Testing
@testable import MouthtypeCore

/// The original full-table alignment, kept as the reference the trimmed one must match.
private func referenceAlign(_ old: [String], _ new: [String]) -> [VocabularyBooster.Run] {
    typealias Run = VocabularyBooster.Run
    let rows = old.count, cols = new.count
    var table = [[Int]](repeating: [Int](repeating: 0, count: cols + 1), count: rows + 1)
    for r in stride(from: rows - 1, through: 0, by: -1) {
        for c in stride(from: cols - 1, through: 0, by: -1) {
            table[r][c] = old[r] == new[c] ? table[r + 1][c + 1] + 1 : max(table[r + 1][c], table[r][c + 1])
        }
    }
    var runs: [Run] = []
    var r = 0, c = 0
    while r < rows || c < cols {
        if r < rows, c < cols, old[r] == new[c] {
            runs.append(.same(old: r, new: c))
            r += 1
            c += 1
            continue
        }
        let (startOld, startNew) = (r, c)
        while r < rows || c < cols {
            if r < rows, c < cols, old[r] == new[c] { break }
            if c >= cols || (r < rows && table[r + 1][c] >= table[r][c + 1]) { r += 1 } else { c += 1 }
        }
        runs.append(.changed(old: startOld..<r, new: startNew..<c))
    }
    return runs
}

private struct SeededRNG: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

private func sameCount(_ runs: [VocabularyBooster.Run]) -> Int {
    runs.reduce(0) { if case .same = $1 { $0 + 1 } else { $0 } }
}

/// Every word is covered once, in order, and `same` pairs are equal words.
private func isWellFormed(_ runs: [VocabularyBooster.Run], _ old: [String], _ new: [String]) -> Bool {
    var r = 0, c = 0
    for run in runs {
        switch run {
        case let .same(o, n):
            guard o == r, n == c, o < old.count, n < new.count, old[o] == new[n] else { return false }
            r += 1
            c += 1
        case let .changed(o, n):
            guard o.lowerBound == r, n.lowerBound == c, !(o.isEmpty && n.isEmpty) else { return false }
            r = o.upperBound
            c = n.upperBound
        }
    }
    return r == old.count && c == new.count
}

@Suite struct VocabularyBoosterAlignTests {
    private func mutate(_ old: [String], _ rng: inout SeededRNG, fresh: Bool) -> [String] {
        var new = old
        for _ in 0..<Int.random(in: 0...4, using: &rng) {
            switch Int.random(in: 0...2, using: &rng) {
            case 0 where !new.isEmpty: new.remove(at: Int.random(in: 0..<new.count, using: &rng))
            case 1: new.insert(fresh ? "ins\(Int.random(in: 0..<1000, using: &rng))" : "w\(Int.random(in: 0...5, using: &rng))",
                               at: Int.random(in: 0...new.count, using: &rng))
            case 2 where !new.isEmpty: new[Int.random(in: 0..<new.count, using: &rng)] = "x\(Int.random(in: 0..<3, using: &rng))"
            default: break
            }
        }
        return new
    }

    /// Distinct words have one possible alignment, so the trimmed result must match the old one exactly.
    @Test func matchesReferenceExactlyWithDistinctWords() {
        var rng = SeededRNG(state: 42)
        for _ in 0..<3000 {
            let old = (0..<Int.random(in: 0...14, using: &rng)).map { "w\($0)" }
            let new = mutate(old, &rng, fresh: true)
            #expect(VocabularyBooster.align(old, new) == referenceAlign(old, new), "old \(old) new \(new)")
        }
    }

    /// Repeated words allow several equally good alignments. The trimmed one may pick a different tie, so check it is
    /// well formed and as long as the reference.
    @Test func matchesReferenceQualityWithRepeatedWords() {
        var rng = SeededRNG(state: 7)
        for _ in 0..<3000 {
            let alphabet = Int.random(in: 1...4, using: &rng)
            let old = (0..<Int.random(in: 0...14, using: &rng)).map { _ in "w\(Int.random(in: 0..<alphabet, using: &rng))" }
            let new = Bool.random(using: &rng)
                ? mutate(old, &rng, fresh: false)
                : (0..<Int.random(in: 0...14, using: &rng)).map { _ in "w\(Int.random(in: 0..<alphabet, using: &rng))" }
            let runs = VocabularyBooster.align(old, new)
            #expect(isWellFormed(runs, old, new), "old \(old) new \(new)")
            #expect(sameCount(runs) == sameCount(referenceAlign(old, new)), "old \(old) new \(new)")
        }
    }

    /// More than the Myers edit cap, so this goes through the table fallback.
    @Test func heavilyEditedMiddleStillMatchesReference() {
        let old = (0..<900).map { "a\($0)" }
        let new = (0..<900).map { $0 % 3 == 0 ? "a\($0)" : "b\($0)" }
        #expect(VocabularyBooster.align(old, new) == referenceAlign(old, new))
    }

    @Test func cheapOnLargeNearlyIdenticalTake() {
        let old = (0..<12_000).map { "word\($0)" }
        var new = old
        new[6000] = "changed"
        let start = ContinuousClock.now
        let runs = VocabularyBooster.align(old, new)
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(runs.count == 12_000 - 1 + 1)
    }
}

