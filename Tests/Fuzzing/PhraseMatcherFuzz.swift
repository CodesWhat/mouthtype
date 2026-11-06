import Foundation

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzPhraseMatcher(_ data: UnsafePointer<UInt8>?, _ count: Int) -> Int32 {
    guard (0...4096).contains(count), count == 0 || data != nil else { return 0 }
    let input = String(decoding: UnsafeBufferPointer(start: data, count: count), as: UTF8.self)
    let parts = input.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
    let header = parts.first.map(String.init) ?? ""
    let text = parts.count > 1 ? String(parts[1]) : header
    let patterns = header.split(separator: "|", omittingEmptySubsequences: false).prefix(16).map { String($0.prefix(64)) }
    let matcher = PhraseMatcher(patterns: patterns)
    let chars = Array(text)
    let lower = TextScan.lowered(chars)

    func check(_ match: PhraseMatcher.Match) {
        precondition(match.range.lowerBound >= 0 && match.range.upperBound <= chars.count && !match.range.isEmpty)
        precondition(patterns.indices.contains(match.pattern))
        precondition(match.range.lowerBound == 0 || !TextScan.isWordChar(chars[match.range.lowerBound - 1]))
        precondition(match.range.upperBound == chars.count || !TextScan.isWordChar(chars[match.range.upperBound]))
        let expected = TextScan.lowered(Array(PhraseKey.collapsed(patterns[match.pattern])))
        // Collapse the pattern only once, as the matcher does. Rebuilding and collapsing the matched substring can
        // discard a combining mark that attached to a space when the pattern's whitespace was collapsed.
        let literals = expected.split(separator: " ", omittingEmptySubsequences: false)
        var remaining = lower[match.range]
        for (index, literal) in literals.enumerated() {
            if index > 0 {
                let whitespace = remaining.prefix(while: \.isWhitespace)
                precondition(!whitespace.isEmpty)
                remaining = remaining.dropFirst(whitespace.count)
            }
            precondition(remaining.starts(with: literal))
            remaining = remaining.dropFirst(literal.count)
        }
        precondition(remaining.isEmpty)
    }

    var end = 0
    for match in matcher.matches(chars, lower: lower) {
        check(match)
        precondition(match.range.lowerBound >= end)
        end = match.range.upperBound
    }
    var ends: [Int: Int] = [:]
    for match in matcher.allMatches(chars, lower: lower) {
        check(match)
        precondition(match.range.lowerBound >= ends[match.pattern, default: 0])
        ends[match.pattern] = match.range.upperBound
    }
    for word in TextScan.words(chars, lower) {
        precondition(word.start >= 0 && word.start < word.end && word.end <= chars.count)
        _ = TextScan.capitalized(chars, word)
    }
    return 0
}
