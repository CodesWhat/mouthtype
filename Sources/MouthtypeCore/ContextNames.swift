import Foundation

/// Names and proper nouns read from the text around the cursor and the window title, to bias recognition toward
/// while dictating. Pure and in memory: nothing is stored or logged, and the terms live for one dictation.
public enum ContextNames {
    /// Most names one dictation adds.
    public static let maxTerms = 30
    /// Shorter words sit too close to ordinary speech for a boost to be safe.
    public static let minLength = 4
    public static let maxLength = 30

    /// Capitalised words that read as names, nearest the cursor first, then the title. Words that open a sentence are
    /// capitalised anyway, and everyday words ("Thanks", "Monday") are never names, so both kinds are dropped. All-caps
    /// words (acronyms, shouting) are dropped too. Case-insensitive duplicates keep the first spelling seen.
    public static func candidates(
        before: String?, after: String?, windowTitle: String? = nil, excluding: [String] = []
    ) -> [String] {
        let skip = Set(excluding.flatMap { $0.split(whereSeparator: { !$0.isLetter }) }.map { $0.lowercased() })
        var seen = Set<String>()
        var found: [String] = []
        func take(_ words: [String]) {
            for word in words where found.count < maxTerms * 2 {
                let lower = word.lowercased()
                guard !skip.contains(lower), seen.insert(lower).inserted else { continue }
                found.append(word)
            }
        }
        take(names(in: before ?? "").reversed())
        take(names(in: after ?? ""))
        take(names(in: windowTitle ?? ""))
        return found
    }

    /// The boost terms for one dictation, at most `maxTerms`.
    public static func terms(
        before: String?, after: String?, windowTitle: String? = nil, excluding: [String] = []
    ) -> [VocabularyBias.Term] {
        candidates(before: before, after: after, windowTitle: windowTitle, excluding: excluding)
            .prefix(maxTerms).map { VocabularyBias.Term(text: $0) }
    }

    private static let pattern = try? NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_'’-])\p{Lu}\p{L}+(?![\p{L}\p{N}_-])"#)

    /// Name-shaped words of `text` in reading order.
    private static func names(in text: String) -> [String] {
        guard let pattern else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match -> String? in
            guard let range = Range(match.range, in: text) else { return nil }
            let word = String(text[range])
            guard (minLength...maxLength).contains(word.count), word != word.uppercased() else { return nil }
            let lower = word.lowercased()
            guard !CommonWords.set.contains(lower), !OrdinaryWords.isOrdinary(lower) else { return nil }
            return word
        }
    }
}
