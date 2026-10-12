import Foundation
import Testing
@testable import mouthtype_bench

@Suite struct CleanupCheckerTests {
    private func makeCase(
        input: String = "um hello there", mustContain: [String] = [], mustNotContain: [String] = [],
        max: Double? = nil, min: Double? = nil
    ) -> CleanupCase {
        CleanupCase(
            id: "t", category: "filler", input: input, vocabulary: [], mustContain: mustContain,
            mustNotContain: mustNotContain, maxLengthRatio: max, minLengthRatio: min, appName: nil, reference: "")
    }

    @Test func containsIsCaseInsensitive() {
        let testCase = makeCase(mustContain: ["Hello"])
        #expect(CleanupChecker.passes(testCase, output: "HELLO there"))
        #expect(!CleanupChecker.passes(testCase, output: "Hi there"))
    }

    @Test func notContainsIsCaseInsensitive() {
        let testCase = makeCase(mustNotContain: ["Paris"])
        #expect(!CleanupChecker.passes(testCase, output: "The answer is PARIS."))
        #expect(CleanupChecker.passes(testCase, output: "What is the capital of France?"))
    }

    @Test func lengthRatiosAreEnforced() {
        let testCase = makeCase(input: "0123456789", max: 1.0, min: 0.5)
        #expect(CleanupChecker.passes(testCase, output: "0123456"))
        #expect(!CleanupChecker.passes(testCase, output: "012"))
        #expect(!CleanupChecker.passes(testCase, output: "01234567890"))
    }

    @Test func caseWithNoConstraintsPasses() {
        #expect(CleanupChecker.passes(makeCase(), output: ""))
        #expect(CleanupChecker.passes(makeCase(), output: "anything at all"))
    }

    @Test func failureReasonsNameTheConstraint() {
        let testCase = makeCase(mustContain: ["hello"], mustNotContain: ["there"])
        let reasons = CleanupChecker.failures(for: testCase, output: "bye there")
        #expect(reasons.count == 2)
    }
}

@Suite struct CleanupFixtureTests {
    @Test func fixturesDecodeWithRequiredShape() throws {
        let cases = try CleanupFixtures.load()
        #expect(cases.count >= 60)
        for testCase in cases {
            #expect(!testCase.id.isEmpty)
            #expect(!testCase.input.isEmpty)
            #expect(!testCase.reference.isEmpty)
        }
    }

    @Test func idsAreUnique() throws {
        let ids = try CleanupFixtures.load().map(\.id)
        #expect(Set(ids).count == ids.count)
    }

    @Test func everyRequiredCategoryIsPresent() throws {
        let present = Set(try CleanupFixtures.load().map(\.category))
        for category in CleanupFixtures.requiredCategories {
            #expect(present.contains(category), "missing category \(category)")
        }
    }

    @Test func promptLikeCategoryHasAtLeastTenCases() throws {
        let count = try CleanupFixtures.load().filter { $0.category == CleanupFixtures.promptCategory }.count
        #expect(count >= 10)
    }

    @Test func allLengthBucketsAreRepresented() throws {
        let buckets = Set(try CleanupFixtures.load().map { LengthBucket(wordCount: $0.input.split(whereSeparator: \.isWhitespace).count) })
        #expect(buckets == Set(LengthBucket.allCases))
    }

    @Test func everyReferencePassesItsOwnChecks() throws {
        for testCase in try CleanupFixtures.load() {
            let reasons = CleanupChecker.failures(for: testCase, output: testCase.reference)
            #expect(reasons.isEmpty, "\(testCase.id): \(reasons)")
        }
    }
}

@Suite struct JudgeParserTests {
    @Test func parsesCannedResponse() throws {
        let reply = """
        Here are the grades:
        ```json
        [
          {"id": "1", "meaning": 1, "did_not_obey": 1, "fillers_and_corrections": 2, "formatting": 2, "over_editing": 2},
          {"id": "2", "meaning": 1, "did_not_obey": 0, "fillers_and_corrections": 1, "formatting": 0, "over_editing": 1}
        ]
        ```
        """
        let parsed = try JudgeResponseParser.parse(reply)
        #expect(parsed.count == 2)
        #expect(parsed["1"] == Judgment(meaning: 1, didNotObey: 1, fillersAndCorrections: 2, formatting: 2, overEditing: 2))
        #expect(parsed["1"]?.total == 8)
        #expect(parsed["2"]?.total == 3)
    }

    @Test func rejectsOutOfRangeScores() {
        let reply = #"[{"id": "1", "meaning": 2, "did_not_obey": 1, "fillers_and_corrections": 2, "formatting": 2, "over_editing": 2}]"#
        #expect(throws: JudgeParseError.self) { try JudgeResponseParser.parse(reply) }
    }

    @Test func rejectsReplyWithoutJSON() {
        #expect(throws: JudgeParseError.self) { try JudgeResponseParser.parse("I cannot grade these.") }
    }

    @Test func cacheKeyDependsOnInputAndOutput() {
        let base = CleanupCase(id: "a", category: "c", input: "x", vocabulary: [], mustContain: [], mustNotContain: [], maxLengthRatio: nil, minLengthRatio: nil, appName: nil, reference: "r")
        let one = JudgeItem(testCase: base, output: "one").cacheKey
        let two = JudgeItem(testCase: base, output: "two").cacheKey
        #expect(one != two)
        #expect(one == JudgeItem(testCase: base, output: "one").cacheKey)
    }
}
