import Foundation

/// One planned change to a stage's input. Offsets are Character offsets into the text as it entered the stage.
///
/// `range` is what gets logged (the words that were heard). `cut` is what is actually replaced and may extend
/// over neighbouring spaces so the removal leaves no gap; the spaces are tidying and are not logged.
public struct TextSpan: Sendable, Equatable {
    public var range: Range<Int>
    public var cut: Range<Int>
    public var replacement: String

    public init(range: Range<Int>, cut: Range<Int>? = nil, replacement: String) {
        self.range = range
        self.cut = cut ?? range
        self.replacement = replacement
    }
}

/// What a text stage hands back: the new text, the edits it made, and any diagnostics worth surfacing.
public struct StageResult: Sendable, Equatable {
    public var text: String
    public var edits: [EditOp]
    public var notes: [String]

    public init(text: String, edits: [EditOp] = [], notes: [String] = []) {
        self.text = text
        self.edits = edits
        self.notes = notes
    }
}

enum SpanRewriter {
    private static let spaceSet = CharacterSet(charactersIn: " \t")

    /// Applies spans left to right. A span that starts inside an earlier span's cut is dropped; one whose cut
    /// only grazes the previous cut (shared whitespace) has its cut clamped.
    static func apply(_ spans: [TextSpan], to chars: [Character], stage: String, notes: [String] = []) -> StageResult {
        let ordered = spans.sorted {
            ($0.range.lowerBound, $0.range.upperBound) < ($1.range.lowerBound, $1.range.upperBound)
        }
        var out = ""
        out.reserveCapacity(chars.count)
        var cursor = 0
        var edits: [EditOp] = []
        for span in ordered {
            guard span.range.lowerBound >= cursor, span.cut.upperBound <= chars.count,
                  span.cut.lowerBound <= span.range.lowerBound, span.cut.upperBound >= span.range.upperBound
            else { continue }
            let cutStart = max(span.cut.lowerBound, cursor)
            out.append(contentsOf: chars[cursor..<cutStart])
            out.append(span.replacement)
            cursor = span.cut.upperBound

            let from = String(chars[span.range])
            let to = span.replacement.trimmingCharacters(in: spaceSet)
            if from == to { continue }
            let kind: EditOp.Kind = to.isEmpty ? .delete : (from.isEmpty ? .insert : .replace)
            edits.append(EditOp(
                stage: stage,
                kind: kind,
                fromText: from.isEmpty ? nil : from,
                toText: to.isEmpty ? nil : to,
                wordDelta: TextMetrics.wordCount(to) - TextMetrics.wordCount(from),
                position: span.range.lowerBound
            ))
        }
        out.append(contentsOf: chars[cursor...])
        return StageResult(text: out, edits: edits, notes: notes)
    }
}
