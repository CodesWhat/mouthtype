import Foundation

/// A user dictionary entry. `heard` is what the engine writes, `written` is what the user wants.
///
/// A term to boost with no replacement is a rule where `heard == written` (it corrects the casing of that
/// word). `starred` is a user flag carried with the rule; it has no effect on matching.
public struct DictionaryRule: Sendable, Equatable, Hashable, Codable {
    public var heard: String
    public var written: String
    public var starred: Bool

    public init(heard: String, written: String, starred: Bool = false) {
        self.heard = heard
        self.written = written
        self.starred = starred
    }

    var allowsSpellingHints: Bool {
        heard.caseInsensitiveCompare(written) == .orderedSame || isJoinedSpelling
    }

    public var isJoinedSpelling: Bool {
        let parts = heard.split(whereSeparator: \.isWhitespace)
        return parts.count > 1 && parts.contains(where: { $0.count > 1 }) && parts.allSatisfy { $0.allSatisfy(\.isLetter) }
            && written.allSatisfy(\.isLetter) && parts.joined().caseInsensitiveCompare(written) == .orderedSame
    }
}

/// The dictionary stage: rewrites each rule's `heard` to its `written` form in one pass, so rules cannot chain.
///
/// Whole word, case-insensitive, Unicode-aware boundaries, longest `heard` first, multi-word phrases allowed,
/// `written` inserted exactly as given. A rule whose `heard` or `written` is empty is ignored; the first of
/// several rules with the same `heard` (ignoring case) wins.
///
/// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026
/// Humanitas Labs. See `PhraseMatcher`.
public struct DictionaryReplacer: Sendable {
    public static let stageName = "dictionary"

    public let rules: [DictionaryRule]
    private let matcher: PhraseMatcher

    public init(rules: [DictionaryRule]) {
        let usable = rules.filter { !$0.written.isEmpty }
        self.rules = usable
        self.matcher = PhraseMatcher(patterns: usable.map(\.heard))
    }

    public func apply(_ text: String) -> StageResult {
        guard !matcher.isEmpty, !text.isEmpty else { return StageResult(text: text) }
        let chars = Array(text)
        let hits = matcher.matches(chars, lower: TextScan.lowered(chars))
        guard !hits.isEmpty else { return StageResult(text: text) }
        let spans = hits.map { TextSpan(range: $0.range, replacement: rules[$0.pattern].written) }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    /// Exact aliases are handled by replacement, not by broad phonetic hints.
    func cleanupVocabulary() -> [String] {
        rules.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.allowsSpellingHints }.map(\.written)
    }

    /// The model cannot introduce an exact alias target without a matching source or target phrase.
    static func introducedAlias(input: String, output: String, rules: [DictionaryRule]) -> String? {
        let key = PhraseKey.normalized
        let usable = rules.filter { !key($0.heard).isEmpty && !key($0.written).isEmpty }
        let hints = Set(usable.filter(\.allowsSpellingHints).map { key($0.written) })
        let exact = usable.filter { !hints.contains(key($0.written)) }
        guard !exact.isEmpty else { return nil }
        let sources = exact.flatMap { [$0.heard, $0.written] }
        let destinations = exact.flatMap { [key($0.written), key($0.written)] }
        func counts(_ text: String, patterns: [String], destinations: [String]) -> [String: Int] {
            let chars = Array(text)
            let matches = PhraseMatcher(patterns: patterns).matches(chars, lower: TextScan.lowered(chars))
            return matches.reduce(into: [:]) { $0[destinations[$1.pattern], default: 0] += 1 }
        }
        let allowed = counts(input, patterns: sources, destinations: destinations)
        let produced = counts(output, patterns: exact.map(\.written), destinations: exact.map { key($0.written) })
        return exact.first { produced[key($0.written), default: 0] > allowed[key($0.written), default: 0] }?.written
    }

    /// Convenience used by tests and callers that only want the text.
    public func apply(to text: String) -> String { apply(text).text }
}
