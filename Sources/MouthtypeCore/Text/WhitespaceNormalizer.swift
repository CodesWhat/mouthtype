import Foundation

/// Collapses runs of spaces, removes the space before `, . ; : ? ! … )` and after `(`, trims the ends of the text
/// and of every line, and keeps intended newlines. Not logged: it only tidies.
///
/// A `.` or `:` directly followed by a letter or digit keeps its space (`open .gitignore`, `at .5`), as do `./`
/// and `../` relative paths. `:)`
/// `;)` `:(` smileys keep theirs.
public struct WhitespaceNormalizer: Sendable {
    public init() {}

    public func apply(_ text: String) -> String {
        let chars = Array(text)
        let n = chars.count
        var out: [Character] = []
        out.reserveCapacity(n)
        var pendingSpace = false
        var i = 0
        while i < n {
            let c = chars[i]
            if c.isNewline {
                pendingSpace = false
                out.append(c)
            } else if c.isWhitespace {
                pendingSpace = true
            } else {
                if pendingSpace {
                    let atLineStart = out.isEmpty || out[out.count - 1].isNewline
                    if !atLineStart, !suppressSpace(before: c, at: i, in: chars, previous: out[out.count - 1]) {
                        out.append(" ")
                    }
                    pendingSpace = false
                }
                out.append(c)
            }
            i += 1
        }
        return String(out)
    }

    private func suppressSpace(before c: Character, at i: Int, in chars: [Character], previous: Character) -> Bool {
        if previous == "(" { return true }
        let next: Character? = i + 1 < chars.count ? chars[i + 1] : nil
        switch c {
        case ",", "?", "!", ")", "\u{2026}":
            return true
        case ";", ":":
            if let next, next == ")" || next == "(" { return false }
            if c == ":", let next, TextScan.isWordChar(next) { return false }
            return true
        case ".":
            if let next, TextScan.isWordChar(next) { return false }
            if next == "/" || (next == "." && i + 2 < chars.count && chars[i + 2] == "/") { return false }
            return true
        default:
            return false
        }
    }
}
