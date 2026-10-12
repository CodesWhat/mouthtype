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

    /// Convenience used by tests and callers that only want the text.
    public func apply(to text: String) -> String { apply(text).text }
}
