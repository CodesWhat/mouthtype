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
    private let setup: DictionarySetup

    /// The matcher and derived lists come from `DictionarySetup`, so a take with the same rules as the last one
    /// rebuilds nothing. Any edit to the rule list is a different key and builds fresh.
    public init(rules: [DictionaryRule]) {
        let setup = DictionarySetup.shared(for: rules)
        self.setup = setup
        self.rules = setup.usable
    }

    private var matcher: PhraseMatcher { setup.matcher }

    public func apply(_ text: String) -> StageResult {
        guard !matcher.isEmpty, !text.isEmpty else { return StageResult(text: text) }
        let chars = Array(text)
        let hits = matcher.matches(chars, lower: TextScan.lowered(chars))
        guard !hits.isEmpty else { return StageResult(text: text) }
        let spans = hits.map { TextSpan(range: $0.range, replacement: rules[$0.pattern].written) }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    /// Exact aliases are handled by replacement, not by broad phonetic hints.
    func cleanupVocabulary() -> [String] { setup.cleanupVocabulary }

    /// The model cannot introduce an exact alias target without a matching source or target phrase.
    static func introducedAlias(input: String, output: String, rules: [DictionaryRule]) -> String? {
        guard let plan = DictionarySetup.shared(for: rules).aliasPlan else { return nil }
        let key = PhraseKey.normalized
        func counts(_ text: String, matcher: PhraseMatcher, destinations: [String]) -> [String: Int] {
            let chars = Array(text)
            let matches = matcher.matches(chars, lower: TextScan.lowered(chars))
            return matches.reduce(into: [:]) { $0[destinations[$1.pattern], default: 0] += 1 }
        }
        let allowed = counts(input, matcher: plan.sourceMatcher, destinations: plan.sourceDestinations)
        let produced = counts(output, matcher: plan.writtenMatcher, destinations: plan.writtenKeys)
        return plan.exact.first { produced[key($0.written), default: 0] > allowed[key($0.written), default: 0] }?.written
    }

    /// Convenience used by tests and callers that only want the text.
    public func apply(to text: String) -> String { apply(text).text }
}

/// Everything derived from one rule list, built once and shared. `shared(for:)` keeps the few most recent lists,
/// matched by value, so the same dictionary across takes (the array usually shares one buffer, which makes the
/// comparison immediate) skips the rebuild, and a changed dictionary file produces a different list and a miss.
final class DictionarySetup: @unchecked Sendable {
    struct AliasPlan {
        let exact: [DictionaryRule]
        let sourceMatcher: PhraseMatcher
        let sourceDestinations: [String]
        let writtenMatcher: PhraseMatcher
        let writtenKeys: [String]
    }

    let source: [DictionaryRule]
    let usable: [DictionaryRule]
    let matcher: PhraseMatcher
    private let lock = NSLock()
    private var _cleanupVocabulary: [String]?
    private var _aliasPlan: AliasPlan??
    private var _bias: VocabularyBias?

    private init(rules: [DictionaryRule]) {
        source = rules
        usable = rules.filter { !$0.written.isEmpty }
        matcher = PhraseMatcher(patterns: usable.map(\.heard))
    }

    var cleanupVocabulary: [String] {
        lock.lock(); defer { lock.unlock() }
        if let cached = _cleanupVocabulary { return cached }
        let built = usable.filter { !$0.heard.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.allowsSpellingHints }.map(\.written)
        _cleanupVocabulary = built
        return built
    }

    var aliasPlan: AliasPlan? {
        lock.lock(); defer { lock.unlock() }
        if let cached = _aliasPlan { return cached }
        let built = buildAliasPlan()
        _aliasPlan = .some(built)
        return built
    }

    /// Rules here are the raw list, not `usable`: alias checks have always keyed off non-blank heard and written.
    private func buildAliasPlan() -> AliasPlan? {
        let key = PhraseKey.normalized
        let rules = source.filter { !key($0.heard).isEmpty && !key($0.written).isEmpty }
        let hints = Set(rules.filter(\.allowsSpellingHints).map { key($0.written) })
        let exact = rules.filter { !hints.contains(key($0.written)) }
        guard !exact.isEmpty else { return nil }
        let keys = exact.map { key($0.written) }
        return AliasPlan(
            exact: exact,
            sourceMatcher: PhraseMatcher(patterns: exact.flatMap { [$0.heard, $0.written] }),
            sourceDestinations: keys.flatMap { [$0, $0] },
            writtenMatcher: PhraseMatcher(patterns: exact.map(\.written)),
            writtenKeys: keys
        )
    }

    var vocabularyBias: VocabularyBias {
        lock.lock(); defer { lock.unlock() }
        if let cached = _bias { return cached }
        let built = VocabularyBias.build(from: source)
        _bias = built
        return built
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var recent: [DictionarySetup] = []
    private static let capacity = 4

    static func shared(for rules: [DictionaryRule]) -> DictionarySetup {
        cacheLock.lock(); defer { cacheLock.unlock() }
        if let at = recent.firstIndex(where: { $0.source == rules }) {
            let hit = recent.remove(at: at)
            recent.insert(hit, at: 0)
            return hit
        }
        let fresh = DictionarySetup(rules: rules)
        recent.insert(fresh, at: 0)
        if recent.count > capacity { recent.removeLast() }
        return fresh
    }
}
