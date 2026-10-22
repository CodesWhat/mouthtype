import Foundation

/// One sub-word unit as the engine reports it, before words are assembled.
struct SubwordUnit: Equatable {
    var text: String
    var start: Double
    var end: Double
    var confidence: Float
}

enum WordAssembly {
    static let boundaryMarker: Character = "\u{2581}"  // SentencePiece "▁"

    private static let skipped: Set<String> = ["", "<blank>", "<pad>"]
    private static let openers: Set<Character> = ["(", "[", "{", "\"", "\u{201C}", "\u{2018}", "\u{00BF}", "\u{00A1}"]

    /// A unit starts a new word when it carries a boundary marker (`▁` or a leading space),
    /// unless it is closing punctuation, which attaches to the word before it.
    static func assemble(_ units: [SubwordUnit]) -> [WordTiming] {
        var words: [WordTiming] = []
        var current: WordTiming?

        for unit in units where !skipped.contains(unit.text) {
            let marked = unit.text.first == boundaryMarker || unit.text.first == " "
            let body = marked ? String(unit.text.dropFirst()) : unit.text
            if body.isEmpty { continue }

            let attaches = current != nil && (!marked || isClosingPunctuation(body))
            if attaches, var word = current {
                word.word += body
                word.end = unit.end
                word.confidence = min(word.confidence, unit.confidence)
                current = word
            } else {
                if let current { words.append(current) }
                current = WordTiming(word: body, start: unit.start, end: unit.end, confidence: unit.confidence)
            }
        }
        if let current { words.append(current) }
        return words
    }

    private static func isClosingPunctuation(_ text: String) -> Bool {
        guard let first = text.first, !openers.contains(first) else { return false }
        return text.allSatisfy { $0.isPunctuation || $0.isSymbol }
    }
}
