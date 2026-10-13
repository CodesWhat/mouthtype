import Foundation

/// Turns spoken punctuation and layout words into symbols when they are clearly commands.
///
/// See `SpokenCommandTable` for the vocabulary and `SpokenCommand.Style` for when a phrase counts. Punctuation
/// Parakeet already placed next to the spoken word is absorbed ("hello comma, world" becomes "hello, world").
/// Symbols attach to the previous word, and the word after sentence-ending punctuation or a line break gets a
/// capital. "new line" and "new paragraph" are commands unless a determiner or possessive sits right before
/// them ("a new line of products"). A clause-end word followed by a lowercase word ("send it comma then wait")
/// is read as ordinary speech.
///
/// List commands ("bullet", "numbered list", "next item", "end list") are read in order with a small state: the
/// current list kind and number. Rules: "bullet", "bullet point", "numbered list" and "new bullet" start or
/// continue a list anywhere, but never after a determiner ("the bullet hit"), never as the last word, and a bare
/// "bullet" never before "points"/"train"/"journal" and similar. "next item", "new item", a bare "next" and
/// "end list" count only while a list is open. A bare "next" also needs a non-preposition before it and a
/// non-time word after ("what's next", "next week" stay prose). "new paragraph" closes the list. A marker goes
/// on its own line, the comma the engine put before the command is dropped, the item's first word is capitalised.
/// Known misses: a list item that really contains "next" in prose, and "bullet" used as a noun with no
/// determiner ("silver bullet works") when something follows it.
public struct SpokenCommands: Sendable {
    public static let stageName = "spoken command"

    private let entries: [SpokenCommand]

    public init(entries: [SpokenCommand] = SpokenCommandTable.entries) {
        self.entries = entries.sorted { $0.words.count > $1.words.count }
    }

    private struct Match {
        var entry: SpokenCommand
        var firstWord: Int
        var lastWord: Int
    }

    private static let absorbAfter: Set<Character> = [",", ".", ";", ":", "!", "?", "\u{2026}"]
    private static let layoutAbsorbAfter: Set<Character> = [",", ".", ";", ":"]

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        let n = chars.count
        guard n > 0 else { return StageResult(text: text) }
        let lower = TextScan.lowered(chars)
        let words = TextScan.words(chars, lower)

        // Pass 1: every place a command phrase occurs, ignoring context.
        var raw: [Match] = []
        var w = 0
        while w < words.count {
            var found: Match?
            for entry in entries where w + entry.words.count <= words.count {
                var ok = true
                for (offset, word) in entry.words.enumerated() {
                    let idx = w + offset
                    if words[idx].lower != word { ok = false; break }
                    if offset > 0, !TextScan.onlySpaces(chars, words[idx - 1].end, words[idx].start) { ok = false; break }
                    if offset > 0, words[idx - 1].end == words[idx].start { ok = false; break }
                }
                if ok { found = Match(entry: entry, firstWord: w, lastWord: w + entry.words.count - 1); break }
            }
            if let found { raw.append(found); w = found.lastWord + 1 } else { w += 1 }
        }
        guard !raw.isEmpty else { return StageResult(text: text) }
        let startsRaw: [Int: Match] = Dictionary(uniqueKeysWithValues: raw.map { ($0.firstWord, $0) })

        // Pass 2: decide which matches are commands, and build spans.
        var spans: [TextSpan] = []
        var commandStarts = Set<Int>()
        var accepted: [(match: Match, coreStart: Int, coreEnd: Int, replacement: String?)] = []
        var listState = ListState()
        for m in raw {
            let first = words[m.firstWord], last = words[m.lastWord]
            // Noun signal directly before.
            if m.firstWord > 0 {
                let prev = words[m.firstWord - 1]
                if TextScan.onlySpaces(chars, prev.end, first.start), prev.end < first.start {
                    let signals = m.entry.style == .layout
                        ? SpokenCommandTable.layoutNounSignals : SpokenCommandTable.nounSignals
                    if signals.contains(prev.lower) { continue }
                }
            }
            if let action = m.entry.list, !listCommandApplies(action, m, chars, words, listState) { continue }
            var coreStart = first.start
            var coreEnd = last.end
            switch m.entry.attach {
            case .previous, .spaced, .both:
                if m.entry.attach == .previous {
                    while coreEnd < n, Self.absorbAfter.contains(chars[coreEnd]) { coreEnd += 1 }
                }
            case .newline:
                while coreEnd < n, Self.layoutAbsorbAfter.contains(chars[coreEnd]) { coreEnd += 1 }
            case .next:
                break
            }
            var replacement: String?
            if let action = m.entry.list {
                // The comma the engine put before the command only separated the previous item.
                var j = coreStart - 1
                while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
                if j >= 0, chars[j] == "," { coreStart = j }
                replacement = listState.apply(
                    action, atLineStart: atLineStart(chars, coreStart, accepted, m), hasText: m.lastWord + 1 < words.count
                )
            } else if m.entry.attach == .newline, m.entry.output == "\n\n" {
                listState.close()
            }
            if m.entry.style == .clauseEnd {
                guard isClauseEnd(chars, words, after: m, coreEnd: coreEnd, startsRaw: startsRaw) else { continue }
            }
            if m.entry.attach == .previous {
                // A comma (or the same symbol) Parakeet put just before the spoken word is a duplicate.
                var j = coreStart - 1
                while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
                if j >= 0, chars[j] == "," || String(chars[j]) == m.entry.output {
                    coreStart = j
                }
            }
            accepted.append((m, coreStart, coreEnd, replacement))
            commandStarts.insert(m.firstWord)
        }

        var lastCutEnd = 0
        for (m, coreStart, coreEnd, listReplacement) in accepted {
            var cutStart = coreStart
            var cutEnd = coreEnd
            var replacement = listReplacement ?? m.entry.output
            switch m.entry.attach {
            case .previous:
                while cutStart > lastCutEnd, TextScan.isSpace(chars[cutStart - 1]) { cutStart -= 1 }
                if cutEnd < n, TextScan.isWordChar(chars[cutEnd]) { replacement += " " }
            case .newline, .both, .spaced:
                while cutStart > lastCutEnd, TextScan.isSpace(chars[cutStart - 1]) { cutStart -= 1 }
                while cutEnd < n, TextScan.isSpace(chars[cutEnd]) { cutEnd += 1 }
            case .next:
                while cutEnd < n, TextScan.isSpace(chars[cutEnd]) { cutEnd += 1 }
            }
            spans.append(TextSpan(range: coreStart..<coreEnd, cut: cutStart..<cutEnd, replacement: replacement))
            lastCutEnd = cutEnd

            // Capital after a sentence end, unless the next word is itself a command.
            if m.entry.endsSentence {
                let next = m.lastWord + 1
                if next < words.count, !commandStarts.contains(next) {
                    var gapOK = true
                    var i = coreEnd
                    while i < words[next].start {
                        if !chars[i].isWhitespace { gapOK = false; break }
                        i += 1
                    }
                    if gapOK, let up = TextScan.capitalized(chars, words[next]) {
                        spans.append(TextSpan(range: words[next].start..<words[next].end, replacement: up))
                        lastCutEnd = max(lastCutEnd, words[next].end)
                    }
                }
            }
        }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    /// Where the open list stands while the matches are read in order.
    private struct ListState {
        enum Kind { case bullet, numbered }
        var kind: Kind?
        var number = 0

        var isOpen: Bool { kind != nil }

        mutating func close() { kind = nil; number = 0 }

        /// Moves the state on and returns the text that replaces the command.
        mutating func apply(_ action: SpokenCommand.ListAction, atLineStart: Bool, hasText: Bool) -> String {
            let lead = atLineStart ? "" : "\n"
            switch action {
            case .bullet, .newBullet:
                kind = .bullet
                number = 0
                return lead + "- "
            case .numbered:
                kind = .numbered
                number = 1
                return lead + "1. "
            case .nextItem, .next:
                if kind == .numbered {
                    number += 1
                    return lead + "\(number). "
                }
                return lead + "- "
            case .end:
                close()
                return atLineStart || !hasText ? "" : "\n"
            }
        }
    }

    private func listCommandApplies(
        _ action: SpokenCommand.ListAction, _ m: Match, _ chars: [Character], _ words: [ScanWord], _ state: ListState
    ) -> Bool {
        let next = m.lastWord + 1
        let hasText = next < words.count
        switch action {
        case .newBullet:
            return true
        case .bullet:
            guard hasText else { return false }
            return m.entry.words.count == 2 || !SpokenCommandTable.bulletFollowers.contains(words[next].lower)
        case .numbered:
            return hasText
        case .nextItem:
            return state.isOpen && hasText
        case .next:
            guard state.isOpen, hasText else { return false }
            if SpokenCommandTable.nextFollowers.contains(words[next].lower) { return false }
            if m.firstWord > 0, SpokenCommandTable.nextPrepositions.contains(words[m.firstWord - 1].lower) { return false }
            return true
        case .end:
            return state.isOpen
        }
    }

    /// Whether the command starts a line: the start of the text, a newline before it, or a command just before it
    /// that left the cursor at the start of a line.
    private func atLineStart(
        _ chars: [Character], _ start: Int,
        _ accepted: [(match: Match, coreStart: Int, coreEnd: Int, replacement: String?)], _ m: Match
    ) -> Bool {
        var j = start - 1
        while j >= 0, TextScan.isSpace(chars[j]) { j -= 1 }
        if j < 0 || chars[j].isNewline { return true }
        if let last = accepted.last, last.match.lastWord + 1 == m.firstWord {
            let out = last.replacement ?? last.match.entry.output
            return out.hasSuffix("\n") || (last.match.entry.list != nil && (out.hasSuffix("- ") || out.hasSuffix(". ")))
        }
        return false
    }

    private func isClauseEnd(
        _ chars: [Character], _ words: [ScanWord], after m: Match, coreEnd: Int, startsRaw: [Int: Match]
    ) -> Bool {
        let n = chars.count
        // Punctuation Parakeet attached to the word counts as the clause end.
        if coreEnd > words[m.lastWord].end { return true }
        var i = coreEnd
        while i < n, TextScan.isSpace(chars[i]) { i += 1 }
        if i >= n || chars[i].isNewline { return true }
        if ")]}\"\u{201D}".contains(chars[i]) { return true }
        if !TextScan.isWordChar(chars[i]) { return true }
        let next = m.lastWord + 1
        guard next < words.count, words[next].start == i else { return false }
        if chars[i].isUppercase { return true }
        if let other = startsRaw[next], other.entry.style != .clauseEnd {
            // Item separators and "end list" only count inside a list, which a clause end does not open.
            switch other.entry.list {
            case .nextItem, .next, .end: return false
            default: return true
            }
        }
        return false
    }
}
