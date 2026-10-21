import Foundation

/// Names and spellings to bias recognition toward. Recognition-time only: an engine that adopts
/// `VocabularyBiasing` uses these while it recognises. This is not the dictionary replacer, which rewrites
/// finished text and isn't acoustic boosting.
public struct VocabularyBias: Sendable, Equatable {
    /// One spelling to favour, plus the spoken-form spellings the user saved for it.
    public struct Term: Sendable, Equatable {
        public let text: String
        /// Distinct heard forms other than `text` itself.
        public let aliases: [String]

        public init(text: String, aliases: [String] = []) {
            self.text = text
            self.aliases = aliases
        }
    }

    /// Most terms one vocabulary carries. There is no character cap.
    public static let maxTerms = 200

    public let entries: [Term]

    /// The written spellings, in order.
    public var terms: [String] { entries.map(\.text) }

    /// Trims, drops empties and case-insensitive duplicates (merging their aliases), keeps order, stops at `maxTerms`.
    public init(entries: [Term], maxTerms: Int = VocabularyBias.maxTerms) {
        var kept: [Term] = []
        var index: [String: Int] = [:]
        for raw in entries {
            let text = Self.normalise(raw.text)
            guard !text.isEmpty else { continue }
            let key = text.lowercased()
            if let at = index[key] {
                kept[at] = Term(text: kept[at].text, aliases: Self.distinct(kept[at].aliases + raw.aliases, excluding: key))
            } else if kept.count < maxTerms {
                index[key] = kept.count
                kept.append(Term(text: text, aliases: Self.distinct(raw.aliases, excluding: key)))
            }
        }
        self.entries = kept
    }

    public init(terms: [String], maxTerms: Int = VocabularyBias.maxTerms) {
        self.init(entries: terms.map { Term(text: $0) }, maxTerms: maxTerms)
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// The text an engine encodes as a decoding prompt.
    public var promptText: String { terms.joined(separator: ", ") }

    /// The spellings the user wants written: starred rules first, then the rest in saved order. Heard forms
    /// of rules sharing a written spelling become that term's aliases, except everyday words, which would
    /// boost the written spelling whenever that ordinary word is said. The written spelling still boosts.
    public static func collect(from rules: [DictionaryRule]) -> VocabularyBias {
        DictionarySetup.shared(for: rules).vocabularyBias
    }

    static func build(from rules: [DictionaryRule]) -> VocabularyBias {
        let usable = rules.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let ordered = usable.filter(\.starred) + usable.filter { !$0.starred }
        return VocabularyBias(entries: ordered.map { Term(text: $0.written, aliases: OrdinaryWords.suppressesAlias($0) ? [] : [$0.heard]) })
    }

    private static func normalise(_ raw: String) -> String {
        raw.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// Normalised, non-empty, case-insensitively distinct, and never the term's own spelling.
    private static func distinct(_ aliases: [String], excluding own: String) -> [String] {
        var seen: Set<String> = [own]
        return aliases.map(normalise).filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }
    }
}

/// An engine whose decoder accepts a recognition-time bias. Engines without a hook don't adopt it and ignore the setting.
public protocol VocabularyBiasing: Transcriber {
    /// Applies to later `transcribe` calls. Nil or empty clears it.
    func setVocabularyBias(_ bias: VocabularyBias?) async
    /// As above, but a changed vocabulary may also wait up to `settleWithin` for the engine to be ready for it.
    /// Nil never waits. Engines with nothing to wait on ignore the budget.
    func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async
}

public extension VocabularyBiasing {
    func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async {
        await setVocabularyBias(bias)
    }
}

public extension VocabularyBias {
    /// How long a take whose terms include the editor's waits for the boost model to rebuild.
    static let editorSettle: Duration = .milliseconds(400)
}
