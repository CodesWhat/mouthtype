import Foundation

/// Metaphone-style phonetic keys and edit distance, used to spot a saved spelling that the recogniser keeps mishearing.
enum PhoneticKey {
    /// A simplified Metaphone: consonant skeleton of how the word sounds ("Siobhan" and "Shaban" both reduce to the
    /// same shape once sibilants and labials are folded by `classKey`).
    static func metaphone(_ word: String) -> String {
        let a: [Character] = word.folding(options: .diacriticInsensitive, locale: nil).lowercased().filter { ("a"..."z").contains($0) }
        let n = a.count
        guard n > 0 else { return "" }
        func at(_ i: Int) -> Character? { i >= 0 && i < n ? a[i] : nil }
        func isVowel(_ c: Character?) -> Bool { c.map { "aeiou".contains($0) } ?? false }
        var out = ""
        var i = 0
        switch (a[0], at(1)) {
        case ("a", "e"): out = "E"; i = 2
        case ("g", "n"), ("k", "n"), ("p", "n"), ("w", "r"): i = 1
        case ("x", _): out = "S"; i = 1
        case ("w", "h"): out = "W"; i = 2
        default: break
        }
        while i < n {
            let c = a[i]
            let prev = at(i - 1)
            let next = at(i + 1)
            let next2 = at(i + 2)
            if c == prev, c != "c" { i += 1; continue }
            switch c {
            case "a", "e", "i", "o", "u":
                if i == 0 { out.append(Character(c.uppercased())) }
            case "b":
                if !(i == n - 1 && prev == "m") { out.append("B") }
            case "c":
                if next == "i", next2 == "a" { out.append("X") }
                else if next == "h" { out.append(prev == "s" ? "K" : "X"); i += 1 }
                else if let nx = next, "iey".contains(nx) { if prev != "s" { out.append("S") } }
                else { out.append("K") }
            case "d":
                if next == "g", let n2 = next2, "eiy".contains(n2) { out.append("J"); i += 1 } else { out.append("T") }
            case "g":
                if next == "h" {
                    if isVowel(next2) { out.append("K") }
                    i += 1
                } else if next == "n", next2 == nil || (next2 == "e" && at(i + 3) == "d" && at(i + 4) == nil) {
                    break
                } else if let nx = next, "iey".contains(nx), prev != "g" { out.append("J") }
                else { out.append("K") }
            case "h":
                if isVowel(next), !(prev.map { "cgpst".contains($0) } ?? false) { out.append("H") }
            case "k":
                if prev != "c" { out.append("K") }
            case "p":
                if next == "h" { out.append("F"); i += 1 } else { out.append("P") }
            case "q": out.append("K")
            case "s":
                if next == "h" { out.append("X"); i += 1 }
                else if next == "i", next2 == "o" || next2 == "a" { out.append("X") }
                else { out.append("S") }
            case "t":
                if next == "i", next2 == "a" || next2 == "o" { out.append("X") }
                else if next == "h" { out.append("0"); i += 1 }
                else if !(next == "c" && next2 == "h") { out.append("T") }
            case "v": out.append("F")
            case "w", "y":
                if isVowel(next) { out.append(Character(c.uppercased())) }
            case "x": out.append("KS")
            case "z": out.append("S")
            default: out.append(Character(c.uppercased()))
            }
            i += 1
        }
        return out
    }

    /// Folds sounds the recogniser trades freely (S/SH/CH/J, B/P/F/V, T/D, K/G, M/N) and drops H, so a mishearing
    /// like Shaban for Siobhan lands on the same key.
    static func classKey(_ word: String) -> String {
        var out = ""
        for c in metaphone(word) {
            let mapped: Character
            switch c {
            case "S", "X", "Z", "J": mapped = "S"
            case "P", "B", "F", "V": mapped = "P"
            case "T", "D", "0": mapped = "T"
            case "K", "G", "C", "Q": mapped = "K"
            case "M", "N": mapped = "N"
            case "H": continue
            default: mapped = c
            }
            if out.last != mapped { out.append(mapped) }
        }
        return out
    }

    static func distance(_ lhs: String, _ rhs: String) -> Int {
        let a = Array(lhs.unicodeScalars), b = Array(rhs.unicodeScalars)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var row = Array(0...b.count)
        for i in 1...a.count {
            var diagonal = row[0]
            row[0] = i
            for j in 1...b.count {
                let above = row[j]
                row[j] = min(row[j] + 1, row[j - 1] + 1, diagonal + (a[i - 1] == b[j - 1] ? 0 : 1))
                diagonal = above
            }
        }
        return row[b.count]
    }

    /// Edit distance over the longer length, 0 for identical and 1 for nothing in common.
    static func distanceRatio(_ lhs: String, _ rhs: String) -> Double {
        let longest = max(lhs.unicodeScalars.count, rhs.unicodeScalars.count)
        return longest == 0 ? 0 : Double(distance(lhs, rhs)) / Double(longest)
    }
}
