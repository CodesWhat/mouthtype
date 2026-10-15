import Foundation

/// A spoken trigger and the saved text it expands to.
///
/// The expansion may contain `{date}` (today, long style in the user's locale) and `{clipboard}` (the current
/// clipboard text, or empty when there is none). Any other `{...}` is left as written.
public struct Snippet: Sendable, Equatable, Hashable, Codable {
    public var trigger: String
    public var expansion: String

    public init(trigger: String, expansion: String) {
        self.trigger = trigger
        self.expansion = expansion
    }
}

/// The snippet stage. A trigger, alone or inside a sentence, is replaced by its expansion.
///
/// Same matcher discipline as the dictionary: case-insensitive, whole word, longest trigger wins, one pass, and an
/// expansion is never scanned again (so a snippet cannot trigger another one, and variables inside an expansion
/// are filled once). Punctuation the engine attached to the trigger ("my address.") stays outside the expansion.
public struct SnippetExpander: Sendable {
    public static let stageName = "snippet"
    public typealias DateFormatter = @Sendable (Date) -> String

    /// Long date in the current locale, e.g. "October 12, 2026".
    public static let defaultDateFormatter: DateFormatter = { date in
        date.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale.current))
    }

    private let snippets: [Snippet]
    private let matcher: PhraseMatcher
    private let now: Date
    private let clipboard: String?
    private let dateFormatter: DateFormatter

    public init(
        snippets: [Snippet],
        now: Date,
        clipboard: String?,
        dateFormatter: @escaping DateFormatter = SnippetExpander.defaultDateFormatter
    ) {
        let usable = snippets.filter { !$0.trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        self.snippets = usable
        self.matcher = PhraseMatcher(patterns: usable.map(\.trigger))
        self.now = now
        self.clipboard = clipboard
        self.dateFormatter = dateFormatter
    }

    /// The configured triggers heard in order, even when the replacement is identical to the trigger.
    public func matchingTriggers(in text: String) -> [String] {
        let chars = Array(text)
        return matcher.matches(chars, lower: TextScan.lowered(chars)).map { snippets[$0.pattern].trigger }
    }

    public func apply(_ text: String) -> StageResult {
        guard !matcher.isEmpty, !text.isEmpty else { return StageResult(text: text) }
        let chars = Array(text)
        let hits = matcher.matches(chars, lower: TextScan.lowered(chars))
        guard !hits.isEmpty else { return StageResult(text: text) }
        var notes: [String] = []
        let spans = hits.map { hit -> TextSpan in
            let snippet = snippets[hit.pattern]
            let expanded = expand(snippet, notes: &notes)
            return TextSpan(range: hit.range, replacement: expanded)
        }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName, notes: notes)
    }

    /// Fills `{date}` and `{clipboard}` in one left-to-right pass; substituted text is not rescanned.
    func expand(_ snippet: Snippet, notes: inout [String]) -> String {
        let chars = Array(snippet.expansion)
        var out = ""
        var i = 0
        while i < chars.count {
            if chars[i] == "{", let close = (i + 1..<min(chars.count, i + 12)).first(where: { chars[$0] == "}" }) {
                let name = String(chars[(i + 1)..<close]).lowercased()
                if name == "date" {
                    out += dateFormatter(now)
                    i = close + 1
                    continue
                }
                if name == "clipboard" {
                    if let clipboard {
                        out += clipboard
                    } else {
                        notes.append("snippet \"\(snippet.trigger)\": {clipboard} had nothing to paste, expanded to empty")
                    }
                    i = close + 1
                    continue
                }
            }
            out.append(chars[i])
            i += 1
        }
        return out
    }
}
