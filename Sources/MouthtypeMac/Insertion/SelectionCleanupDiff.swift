import Foundation

/// What changed between the selection and the result, for the Transform Selection panel: words that disappeared are struck
/// through in the original, characters that were added or changed are highlighted in the result.
enum SelectionDiff {
    /// Past this many characters in either the original or the result the diffs get expensive, so nothing is highlighted.
    static let characterLimit = 2_000

    private static func withinLimit(_ old: String, _ new: String) -> Bool {
        old.count <= characterLimit && new.count <= characterLimit
    }

    private struct Cache {
        // Keys are exact UTF-8 bytes: `String ==` treats canonically equivalent text (composed vs decomposed é) as equal,
        // and a hit would hand back segments built from the other byte representation.
        var original: (old: [UInt8], new: [UInt8], segments: [Segment])?
        var result: (new: [UInt8], old: [UInt8], segments: [Segment])?
    }
    private static let cache = Locked(Cache())

    private final class Locked<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Value
        init(_ value: Value) { self.value = value }
        func withValue<T>(_ body: (inout Value) -> T) -> T {
            lock.lock()
            defer { lock.unlock() }
            return body(&value)
        }
    }

    struct Segment: Equatable {
        var text: String
        var marked: Bool
    }

    /// The original split into runs, with `marked` on words the result no longer has. Words are compared ignoring case and
    /// punctuation, so "i" becoming "I" or "tomorrow." losing its full stop is not a removal. An empty result (a transform
    /// still running) marks nothing.
    static func original(_ old: String, result new: String) -> [Segment] {
        let oldKey = Array(old.utf8), newKey = Array(new.utf8)
        if let hit = cache.withValue({ $0.original }), hit.old == oldKey, hit.new == newKey { return hit.segments }
        let segments = computeOriginal(old, result: new)
        cache.withValue { $0.original = (oldKey, newKey, segments) }
        return segments
    }

    private static func computeOriginal(_ old: String, result new: String) -> [Segment] {
        guard !old.isEmpty, !new.isEmpty, withinLimit(old, new) else { return [Segment(text: old, marked: false)] }
        let oldTokens = tokens(old)
        let newKeys = tokens(new).filter(\.isWord).map(\.key)
        let removed = Set(
            newKeys.difference(from: oldTokens.filter(\.isWord).map(\.key)).compactMap { change -> Int? in
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
        let newKey = Array(new.utf8), oldKey = Array(old.utf8)
        if let hit = cache.withValue({ $0.result }), hit.new == newKey, hit.old == oldKey { return hit.segments }
        let segments = computeResult(new, original: old)
        cache.withValue { $0.result = (newKey, oldKey, segments) }
        return segments
    }

    private static func computeResult(_ new: String, original old: String) -> [Segment] {
        guard !new.isEmpty, !old.isEmpty, withinLimit(old, new) else { return [Segment(text: new, marked: false)] }
        let characters = Array(new)
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
