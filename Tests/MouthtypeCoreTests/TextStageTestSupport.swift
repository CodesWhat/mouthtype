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
    /// Shared CI runners are noisy, so wall-clock perf budgets get a generous multiple there. A gross regression
    /// still fails CI; the tight local budgets stay as written.
    static let ciTimingScale = 5.0

    static func scale(environment: [String: String] = ProcessInfo.processInfo.environment) -> Double {
        environment["CI"] == nil ? 1 : ciTimingScale
    }

    static let timingScale = scale()

    /// The budget to assert against: `local` on a dev machine, a multiple of it on CI.
    static func budget(_ local: Double) -> Double { local * timingScale }
    static func budget(_ local: Duration) -> Duration { local * timingScale }

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
