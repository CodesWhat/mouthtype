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
        let actual = TextScan.lowered(Array(PhraseKey.collapsed(String(chars[match.range]))))
        let expected = TextScan.lowered(Array(PhraseKey.collapsed(patterns[match.pattern])))
        precondition(actual == expected)
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
