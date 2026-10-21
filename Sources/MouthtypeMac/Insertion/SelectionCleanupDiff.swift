import Foundation

/// What changed between the selection and the result, for the Transform Selection panel: words that disappeared are struck
/// through in the original, characters that were added or changed are highlighted in the result.
enum SelectionDiff {
    /// Past this many characters the character diff gets expensive, so long selections show no highlights.
    static let characterLimit = 2_000

    struct Segment: Equatable {
        var text: String
        var marked: Bool
    }

    /// The original split into runs, with `marked` on words the result no longer has. Words are compared ignoring case and
    /// punctuation, so "i" becoming "I" or "tomorrow." losing its full stop is not a removal. An empty result (a transform
    /// still running) marks nothing.
    static func original(_ old: String, result new: String) -> [Segment] {
        let oldTokens = tokens(old)
        guard !oldTokens.isEmpty, !new.isEmpty, old.count <= characterLimit * 2 else { return [Segment(text: old, marked: false)] }
        let newKeys = tokens(new).filter(\.isWord).map(\.key)
        let removed = Set(newKeys.difference(from: oldTokens.filter(\.isWord).map(\.key)).compactMap { change -> Int? in
            if case let .remove(offset, _, _) = change { return offset }
            return nil
        })
        // `difference(from:)` offsets index the word-only arrays, so walk the words in order alongside the tokens.
        var wordIndex = 0
        var flags: [Bool] = []
        for token in oldTokens {
            if token.isWord {
                flags.append(removed.contains(wordIndex))
                wordIndex += 1
            } else {
                flags.append(false)
            }
        }
        return merge(zip(oldTokens.map(\.text), flags).map { Segment(text: $0, marked: $1) })
    }

    /// The result split into runs, with `marked` on characters that are not in the original.
    static func result(_ new: String, original old: String) -> [Segment] {
        let characters = Array(new)
        guard !characters.isEmpty, characters.count <= characterLimit, old.count <= characterLimit, !old.isEmpty else {
            return [Segment(text: new, marked: false)]
        }
        var added = Set<Int>()
        for change in characters.difference(from: Array(old)) {
            if case let .insert(offset, _, _) = change { added.insert(offset) }
        }
        return merge(characters.enumerated().map { Segment(text: String($1), marked: added.contains($0)) })
    }

    private struct Token {
        var text: String
        var isWord: Bool
        var key: String
    }

    private static func tokens(_ text: String) -> [Token] {
        var result: [Token] = []
        var current = ""
        var currentIsSpace: Bool?
        func flush() {
            guard !current.isEmpty, let space = currentIsSpace else { return }
            let key = current.lowercased().filter { $0.isLetter || $0.isNumber }
            result.append(Token(text: current, isWord: !space, key: key))
            current = ""
        }
        for character in text {
            let space = character.isWhitespace
            if space != currentIsSpace { flush() }
            currentIsSpace = space
            current.append(character)
        }
        flush()
        return result
    }

    private static func merge(_ segments: [Segment]) -> [Segment] {
        var merged: [Segment] = []
        for segment in segments {
            if let last = merged.last, last.marked == segment.marked {
                merged[merged.count - 1].text += segment.text
            } else {
                merged.append(segment)
            }
        }
        return merged
    }
}
