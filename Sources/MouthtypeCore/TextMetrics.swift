import Foundation

public enum TextMetrics {
    public struct ErrorCounts: Sendable, Equatable {
        public let edits: Int
        public let referenceWords: Int
    }

    /// Lowercases, turns curly apostrophes straight, replaces everything that is not a letter, digit or
    /// apostrophe with a space, then drops apostrophes that are not inside a word.
    public static func normalizedWords(_ text: String) -> [String] {
        let folded = text.lowercased()
            .replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{2018}", with: "'")
        let cleaned = String(folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.letters.contains(scalar) || CharacterSet.decimalDigits.contains(scalar) || scalar == "'" {
                return Character(scalar)
            }
            return " "
        })
        return cleaned
            .split(whereSeparator: { $0 == " " })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "'")) }
            .filter { !$0.isEmpty }
    }

    public static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    public static func wordsPerMinute(wordCount: Int, durationSeconds: Double) -> Double {
        guard durationSeconds > 0 else { return 0 }
        return Double(wordCount) / (durationSeconds / 60)
    }

    public static func wordsPerMinute(text: String, durationSeconds: Double) -> Double {
        wordsPerMinute(wordCount: wordCount(text), durationSeconds: durationSeconds)
    }

    public static func errorCounts(reference: String, hypothesis: String) -> ErrorCounts {
        let ref = normalizedWords(reference)
        let hyp = normalizedWords(hypothesis)
        return ErrorCounts(edits: editDistance(ref, hyp), referenceWords: ref.count)
    }

    /// Word error rate: word-level Levenshtein distance over the reference word count, after normalization.
    /// An empty reference has no defined rate, so it returns 0 for an empty hypothesis and 1 otherwise.
    public static func wer(reference: String, hypothesis: String) -> Double {
        let counts = errorCounts(reference: reference, hypothesis: hypothesis)
        if counts.referenceWords == 0 {
            return counts.edits == 0 ? 0 : 1
        }
        return Double(counts.edits) / Double(counts.referenceWords)
    }

    private static func editDistance(_ a: [String], _ b: [String]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(substitution, previous[j] + 1, current[j - 1] + 1)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
