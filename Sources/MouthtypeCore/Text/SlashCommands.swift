import Foundation

/// Turns a spoken slash command into a typed one for coding and agent targets: "slash research" becomes "/research".
///
/// "slash" or "forward slash" followed by one word makes "/" plus that word, lowercased, with no space. The word may
/// continue with spoken "dash", "hyphen" or "underscore" joins ("slash code dash review" becomes "/code-review").
/// Punctuation after the command stays ("slash research?" becomes "/research?"). A bare "slash", one followed by a
/// number ("slash 2"), one followed by a function word ("and slash or"), a noun use ("press the slash key", "a
/// forward slash separates paths"), a command already written with "/", text inside backticks and anything a
/// protected phrase covers are left as spoken. When the command is the whole utterance, the sentence punctuation the
/// engine attached ("Slash research.") is dropped; inside prose it stays after the name.
///
/// Runs before spoken commands so it sees "dash" and "hyphen" as words. The caller runs it only for a coding target.
public struct SlashCommands: Sendable {
    public static let stageName = "slash command"

    private let protectedPhrases: [String]

    public init(protectedPhrases: [String] = []) {
        self.protectedPhrases = protectedPhrases
    }

    private static let joiners: [String: String] = ["dash": "-", "hyphen": "-", "underscore": "_"]

    /// Words that follow "slash" in ordinary speech ("and slash or", "a slash of paint"), never a command name.
    private static let functionWords: Set<String> = [
        "a", "an", "and", "or", "the", "of", "to", "in", "is", "it", "as", "at", "on", "for", "but", "if", "so",
        "we", "you", "i", "that", "this", "then", "not", "with", "by", "be",
    ]

    /// Before "slash": the word is a noun being talked about ("a forward slash", "double slash", "my slash key").
    /// "a", "an" and "the" are not here: "a slash research" is the sentence this stage exists for, and the noun
    /// uses of a bare "the slash" are caught by `nounFollowers`.
    private static let modifiers: Set<String> = [
        "this", "that", "these", "those", "my", "your", "our", "its", "their", "his", "her",
        "each", "every", "any", "no", "back", "double", "trailing", "leading", "forward",
    ]
    /// Before "forward slash": a determiner makes it the character ("a forward slash separates paths").
    private static let determiners: Set<String> = ["the", "a", "an"]

    /// After "slash": it is a noun being described ("slash key", "slash character").
    private static let nounFollowers: Set<String> = [
        "key", "keys", "character", "characters", "symbol", "symbols", "sign", "signs", "mark", "marks",
        "separator", "separators", "delimiter", "delimiters", "button",
    ]

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        guard !chars.isEmpty else { return StageResult(text: text) }
        let lower = TextScan.lowered(chars)
        let words = TextScan.words(chars, lower)
        guard words.contains(where: { $0.lower == "slash" }) else { return StageResult(text: text) }
        let shielded = shields(chars, lower)

        func joined(_ a: ScanWord, _ b: ScanWord) -> Bool {
            b.start > a.end && TextScan.onlySpaces(chars, a.end, b.start)
        }
        func plain(_ word: ScanWord) -> Bool {
            chars[word.start..<word.end].allSatisfy(TextScan.isWordChar)
        }

        var spans: [TextSpan] = []
        var i = 0
        while i < words.count {
            guard words[i].lower == "slash" else { i += 1; continue }
            var start = words[i].start
            if i > 0, words[i - 1].lower == "forward", joined(words[i - 1], words[i]) { start = words[i - 1].start }
            let next = i + 1
            guard next < words.count, joined(words[i], words[next]), plain(words[next]),
                  chars[words[next].start].isLetter, !Self.functionWords.contains(words[next].lower),
                  !Self.nounFollowers.contains(words[next].lower)
            else { i += 1; continue }
            let forward = start != words[i].start
            let head = forward ? i - 1 : i
            let blockers = forward ? Self.modifiers.union(Self.determiners) : Self.modifiers
            if head > 0, joined(words[head - 1], words[head]), blockers.contains(words[head - 1].lower) {
                i += 1
                continue
            }
            var command = "/" + words[next].lower
            var last = next
            while last + 2 < words.count, let glue = Self.joiners[words[last + 1].lower],
                  joined(words[last], words[last + 1]), joined(words[last + 1], words[last + 2]),
                  plain(words[last + 2]), chars[words[last + 2].start].isLetter || chars[words[last + 2].start].isNumber {
                command += glue + words[last + 2].lower
                last += 2
            }
            let end = words[last].end
            i = last + 1
            // A path being dictated ("slash src/app") is not a command name.
            if end < chars.count, chars[end] == "/" { continue }
            if start > 0, chars[start - 1] == "/" { continue }
            guard !shielded[start..<end].contains(true) else { continue }
            var spanEnd = end
            if chars[..<start].allSatisfy(\.isWhitespace) {
                var tail = end
                while tail < chars.count, ".!?,".contains(chars[tail]) { tail += 1 }
                if chars[tail...].allSatisfy(\.isWhitespace) { spanEnd = tail }
            }
            spans.append(TextSpan(range: start..<spanEnd, replacement: command))
        }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    private func shields(_ chars: [Character], _ lower: [Character]) -> [Bool] {
        var result = [Bool](repeating: false, count: chars.count)
        for hit in PhraseMatcher(patterns: protectedPhrases).matches(chars, lower: lower) {
            for index in hit.range { result[index] = true }
        }
        var quoted = false
        for index in chars.indices {
            if chars[index] == "`" { quoted.toggle(); result[index] = true }
            if quoted { result[index] = true }
        }
        return result
    }
}
