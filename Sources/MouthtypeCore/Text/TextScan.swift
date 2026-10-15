import Foundation

/// A run of letters, digits and underscores, with apostrophes kept when they sit between two word characters
/// (`don't`, `o'clock`). Offsets are Character offsets.
struct ScanWord: Sendable, Equatable {
    var start: Int
    var end: Int
    var lower: String
}

enum TextScan {
    static func isWordChar(_ c: Character) -> Bool {
        c.isLetter || c.isNumber || c == "_"
    }

    static func isSpace(_ c: Character) -> Bool {
        c == " " || c == "\t"
    }

    /// Per-Character lowercase. Keeps the array the same length as the input so offsets line up.
    static func lowered(_ chars: [Character]) -> [Character] {
        chars.map { c in
            if let a = c.asciiValue {
                return (a >= 65 && a <= 90) ? Character(UnicodeScalar(a + 32)) : c
            }
            let l = c.lowercased()
            return l.count == 1 ? l[l.startIndex] : c
        }
    }

    static func words(_ chars: [Character], _ lower: [Character]) -> [ScanWord] {
        var result: [ScanWord] = []
        let n = chars.count
        var i = 0
        while i < n {
            guard isWordChar(chars[i]) else { i += 1; continue }
            var j = i + 1
            while j < n {
                if isWordChar(chars[j]) {
                    j += 1
                } else if (chars[j] == "'" || chars[j] == "\u{2019}"), j + 1 < n, isWordChar(chars[j + 1]) {
                    j += 2
                } else {
                    break
                }
            }
            result.append(ScanWord(start: i, end: j, lower: String(lower[i..<j])))
            i = j
        }
        return result
    }

    /// True when every Character in `chars[a..<b]` is a space or tab.
    static func onlySpaces(_ chars: [Character], _ a: Int, _ b: Int) -> Bool {
        guard a <= b else { return false }
        var i = a
        while i < b {
            if !isSpace(chars[i]) { return false }
            i += 1
        }
        return true
    }

    /// Uppercases the first Character of `word` when it is a lowercase letter and the rest of the word has no
    /// capitals (so `iPhone` and `eBay` are left alone). Returns nil when no change applies.
    static func capitalized(_ chars: [Character], _ word: ScanWord) -> String? {
        let first = chars[word.start]
        guard first.isLetter, first.isLowercase else { return nil }
        var i = word.start + 1
        while i < word.end {
            if chars[i].isUppercase { return nil }
            i += 1
        }
        let up = first.uppercased()
        guard up != String(first) else { return nil }
        return up + String(chars[(word.start + 1)..<word.end])
    }
}
