import Foundation

/// Turns spoken punctuation and layout words into symbols when they are clearly commands.
///
/// See `SpokenCommandTable` for the vocabulary and `SpokenCommand.Style` for when a phrase counts. Punctuation
/// Parakeet already placed next to the spoken word is absorbed ("hello comma, world" becomes "hello, world").
/// Symbols attach to the previous word, and the word after sentence-ending punctuation or a line break gets a
/// capital. Known misses: "a new line of products" is converted ("new line" is always a command), and a
/// clause-end word followed by a lowercase word ("send it comma then wait") is read as ordinary speech.
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
        var accepted: [(match: Match, coreStart: Int, coreEnd: Int)] = []
        for m in raw {
            let first = words[m.firstWord], last = words[m.lastWord]
            // Noun signal directly before.
            if m.entry.style != .layout, m.firstWord > 0 {
                let prev = words[m.firstWord - 1]
                if TextScan.onlySpaces(chars, prev.end, first.start), prev.end < first.start,
                   SpokenCommandTable.nounSignals.contains(prev.lower) {
                    continue
                }
            }
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
            accepted.append((m, coreStart, coreEnd))
            commandStarts.insert(m.firstWord)
        }

        var lastCutEnd = 0
        for (m, coreStart, coreEnd) in accepted {
            var cutStart = coreStart
            var cutEnd = coreEnd
            var replacement = m.entry.output
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
        if let other = startsRaw[next], other.entry.style != .clauseEnd { return true }
        return false
    }
}
