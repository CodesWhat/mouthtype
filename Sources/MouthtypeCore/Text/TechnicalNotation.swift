import Foundation

public struct TechnicalNotation: Sendable {
    public static let stageName = "notation"
    private let protectedPhrases: [String]
    private let spellings: [String: String]

    public init(protectedPhrases: [String] = []) {
        self.protectedPhrases = protectedPhrases
        var spellings: [String: String] = [:]
        for phrase in protectedPhrases where phrase.count > 1 && phrase.allSatisfy(\.isLetter) {
            if spellings[phrase.lowercased()] == nil { spellings[phrase.lowercased()] = phrase }
        }
        self.spellings = spellings
    }

    public func apply(_ text: String) -> StageResult {
        let chars = Array(text)
        let words = TextScan.words(chars, TextScan.lowered(chars))
        let shielded = shields(chars)
        var spans: [TextSpan] = []
        var i = 0
        func emit(_ range: Range<Int>, _ replacement: String) {
            guard !shielded[range].contains(true) else { return }
            spans.append(TextSpan(range: range, replacement: replacement))
        }
        while i < words.count {
            let word = words[i]
            let core = coreText(word, chars)
            let literal = words[max(0, i - 3)..<i].contains {
                ["label", "spell", "spelled", "identifier", "variable", "symbol"].contains($0.lower)
            }
            if !literal, core == "USB", word.end - word.start == 3, i + 1 < words.count, let letter = piece(words[i + 1], chars),
                "ABC".contains(letter), horizontal(chars[word.end..<words[i + 1].start])
            {
                emit(word.start..<(words[i + 1].start + 1), spellings["USB\(letter)".lowercased()] ?? "USB-\(letter)")
                i += 2
                continue
            }
            if !literal, core.count == 4, core.hasPrefix("USB"), let last = core.last, "ABC".contains(last) {
                emit(word.start..<(word.start + 4), "USB-\(last)")
                i += 1
                continue
            }
            guard let first = piece(word, chars) else { i += 1; continue }
            var letters = String(first)
            var last = i
            var dotted = false
            while last + 1 < words.count, words[last].end == words[last].start + 1,
                let letter = piece(words[last + 1], chars)
            {
                let gap = chars[words[last].end..<words[last + 1].start]
                guard horizontal(gap) || gap.elementsEqual(".") || gap.elementsEqual("-") else { break }
                dotted = dotted || gap.elementsEqual(".")
                letters.append(letter)
                last += 1
            }
            defer { i = last + 1 }
            guard last > i, (letters.count >= 3 && Set(letters).count > 1) || !letters.contains("I") else { continue }
            if last + 1 < words.count {
                let next = words[last + 1]
                // Bare initials before a capitalized name and a leading article remain ambiguous.
                if chars[next.start].isUppercase, next.end - next.start > 1 { continue }
                if first == "A", sentenceStart(chars, word.start) { continue }
            }
            var end = words[last].start + 1
            if dotted, end < chars.count, chars[end] == "." {
                let possessive = end + 2 < chars.count && "'\u{2019}".contains(chars[end + 1]) && chars[end + 2] == "s"
                let continues =
                    last + 1 < words.count && chars[words[last + 1].start].isLowercase
                    && horizontal(chars[(end + 1)..<words[last + 1].start])
                if possessive || continues { end += 1 }
            }
            let canonical =
                !literal && letters.count == 4 && letters.hasPrefix("USB") && "ABC".contains(letters.last!)
                ? "USB-\(letters.last!)" : letters
            let replacement = spellings[letters.lowercased()] ?? canonical
            emit(word.start..<end, replacement)
        }
        return SpanRewriter.apply(spans, to: chars, stage: Self.stageName)
    }

    private func coreText(_ word: ScanWord, _ chars: [Character]) -> String {
        let text = String(chars[word.start..<word.end])
        return text.hasSuffix("'s") || text.hasSuffix("\u{2019}s") ? String(text.dropLast(2)) : text
    }

    private func piece(_ word: ScanWord, _ chars: [Character]) -> Character? {
        let core = coreText(word, chars)
        guard core.count == 1, let letter = core.first, let ascii = letter.asciiValue, (65...90).contains(ascii) else { return nil }
        return letter
    }

    private func horizontal(_ chars: ArraySlice<Character>) -> Bool {
        !chars.isEmpty && chars.allSatisfy(TextScan.isSpace)
    }

    private func sentenceStart(_ chars: [Character], _ start: Int) -> Bool {
        var p = start - 1
        while p >= 0, TextScan.isSpace(chars[p]) { p -= 1 }
        return p < 0 || ".!?\n\r".contains(chars[p])
    }

    private func shields(_ chars: [Character]) -> [Bool] {
        var result = [Bool](repeating: false, count: chars.count)
        let matcher = PhraseMatcher(patterns: protectedPhrases)
        for hit in matcher.matches(chars, lower: TextScan.lowered(chars)) {
            for index in hit.range { result[index] = true }
        }
        var quoted = false
        for index in chars.indices {
            if chars[index] == "`" { quoted.toggle(); result[index] = true }
            if quoted { result[index] = true }
        }
        var start = 0
        while start < chars.count {
            if chars[start].isWhitespace { start += 1; continue }
            var end = start + 1
            while end < chars.count, !chars[end].isWhitespace { end += 1 }
            let text = String(chars[start..<end])
            let parts = text.split(separator: ".").map { part in
                let bare = part.hasSuffix("'s") || part.hasSuffix("\u{2019}s") ? part.dropLast(2) : part[...]
                return bare.trimmingCharacters(in: .punctuationCharacters)
            }.filter { !$0.isEmpty }
            if text.contains(where: { "/\\@_`".contains($0) }) || (parts.count > 1 && parts.contains(where: { $0.count > 1 })) {
                for index in start..<end { result[index] = true }
            }
            start = end
        }
        return result
    }
}
