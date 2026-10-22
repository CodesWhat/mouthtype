import Foundation
import Testing
@testable import MouthtypeCore

/// One input/expected pair for table-driven stage tests. Prints as the input so a failing row is easy to find.
struct TextCase: Sendable, CustomTestStringConvertible {
    let input: String
    let expected: String
    init(_ input: String, _ expected: String) {
        self.input = input
        self.expected = expected
    }
    var testDescription: String { input.debugDescription }
}

enum TextTestSupport {
    /// Wall-clock perf asserts are skipped on shared CI runners, where a page-thrashing machine makes them noise.
    static let timingAssertsEnabled = ProcessInfo.processInfo.environment["CI"] == nil

    /// Applies `edits` (every position refers to `input`) and returns the result with all whitespace removed, so
    /// the comparison ignores the unlogged spacing tidy.
    static func replay(_ edits: [EditOp], on input: String) -> String {
        var chars = Array(input)
        for e in edits.sorted(by: { $0.position > $1.position }) {
            let from = Array(e.fromText ?? "")
            let to = Array(e.toText ?? "")
            let lo = e.position
            let hi = lo + from.count
            guard lo >= 0, hi <= chars.count, Array(chars[lo..<hi]) == from else { return "<<bad edit \(e)>>" }
            chars.replaceSubrange(lo..<hi, with: to)
        }
        return stripWhitespace(String(chars))
    }

    static func stripWhitespace(_ s: String) -> String {
        String(s.filter { !$0.isWhitespace })
    }
}
