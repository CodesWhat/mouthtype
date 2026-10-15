import ArgumentParser
import Foundation
import Testing
import MouthtypeCore
@testable import mouthtype_bench

@Suite struct CleanupCheckerTests {
    @Test func nameChecksCanRequireExactCasing() throws {
        let data = Data(#"{"id":"case","input":"we may ship","target":"We may ship","exact":["We may ship"],"caseSensitive":true}"#.utf8)
        let testCase = try JSONDecoder().decode(SmartCase.self, from: data)
        #expect(testCase.failure(for: "We may ship") == nil)
        #expect(testCase.failure(for: "We May ship") != nil)
    }

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

@Suite struct NativeCleanupBenchmarkTests {
    @Test func comparisonControlsReachTheModelWithoutReplacingDestination() async throws {
        let base = FakeCleaner { text, _ in text }
        let observed = ObservedCleaner(base, styling: .semiCasual, structure: .prose)
        _ = try await observed.clean("hello there", context: CleanupContext(s1Controls:
            S1MiniControls(destination: .email)))
        #expect(base.contexts.first?.s1Controls == S1MiniControls(styling: .semiCasual, structure: .prose, destination: .email))
    }

    @Test func nativeControlsCanBeComparedWithoutChangingAppSettings() throws {
        let command = try CleanTextCommand.parse([
            "--smart", "light", "--cleaner", "superwhisper-s1-mini",
            "--text", "the main thing the main thing is the build",
            "--s1-style", "semi-casual", "--s1-structure", "prose",
        ])
        try command.validate()
    }

    @Test func nativeControlsRejectOtherModelsAndUnknownValues() throws {
        for args in [
            ["--smart", "light", "--cleaner", "gemma-4-e4b-it-4bit", "--text", "hello there", "--s1-style", "casual"],
            ["--smart", "light", "--cleaner", "superwhisper-s1-mini", "--text", "hello there", "--s1-style", "invented"],
            ["--text", "hello there", "--s1-structure", "lists"],
        ] {
            #expect(throws: (any Error).self) {
                let command = try CleanTextCommand.parse(args)
                try command.validate()
            }
        }
    }
}

@Suite struct CleanupTimingRecordTests {
    @Test func totalTimeIncludesAwaitedModelWork() async {
        let cleaner = FakeCleaner { text, _ in
            try await Task.sleep(for: .milliseconds(30))
            return text
        }
        let run = await SmartRunner.run("the G P U needs a driver", level: .light, smart: SmartCleanup(cleaner: cleaner))
        #expect(run.deterministic == "The GPU needs a driver")
        #expect(run.totalCleanupMilliseconds >= 20)
        #expect(run.totalCleanupMilliseconds >= run.deterministicMilliseconds)
    }

    @Test func recordsIncludeDeterministicAndTotalCleanupTime() throws {
        let data = Data(#"{"id":"t","cleanerID":"s1","level":"light","input":"G P U","deterministic":"GPU","delivered":"GPU","outcome":"skipped","milliseconds":0,"deterministicMilliseconds":0.5,"totalCleanupMilliseconds":0.7}"#.utf8)
        let record = try JSONDecoder().decode(SmartDeliveryRecord.self, from: data)
        let encoded = try JSONEncoder().encode(record)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["deterministicMilliseconds"] as? Double == 0.5)
        #expect(object["totalCleanupMilliseconds"] as? Double == 0.7)
    }
}
