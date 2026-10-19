import Foundation

/// Names and spellings to bias recognition toward. Recognition-time only: an engine that adopts
/// `VocabularyBiasing` hands these to its decoder. This is not the dictionary replacer, which rewrites
/// finished text and isn't acoustic boosting.
public struct VocabularyBias: Sendable, Equatable {
    /// Most terms one request carries. Whisper's prompt window is small and a long list crowds the audio context.
    public static let maxTerms = 40
    /// Most characters across all terms, separators included.
    public static let maxCharacters = 400

    public let terms: [String]

    /// Trims, drops empties and case-insensitive duplicates, keeps order, then stops at the term and character caps.
    public init(terms: [String], maxTerms: Int = VocabularyBias.maxTerms, maxCharacters: Int = VocabularyBias.maxCharacters) {
        var seen = Set<String>()
        var kept: [String] = []
        var used = 0
        for raw in terms {
            let term = raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !term.isEmpty, kept.count < maxTerms else { continue }
            let cost = term.count + (kept.isEmpty ? 0 : 2)
            guard used + cost <= maxCharacters, seen.insert(term.lowercased()).inserted else { continue }
            kept.append(term)
            used += cost
        }
        self.terms = kept
    }

    public var isEmpty: Bool { terms.isEmpty }

    /// The text an engine encodes as its decoding prompt.
    public var promptText: String { terms.joined(separator: ", ") }

    /// The spellings the user wants written: starred rules first, then the rest in saved order.
    public static func collect(from rules: [DictionaryRule]) -> VocabularyBias {
        let usable = rules.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ordered = usable.filter(\.starred) + usable.filter { !$0.starred }
        return VocabularyBias(terms: ordered.map(\.written))
    }
}

/// An engine whose decoder accepts a recognition-time bias. Engines without a hook don't adopt it and ignore the setting.
public protocol VocabularyBiasing: Transcriber {
    /// Applies to later `transcribe` calls. Nil or empty clears it.
    func setVocabularyBias(_ bias: VocabularyBias?) async
}
