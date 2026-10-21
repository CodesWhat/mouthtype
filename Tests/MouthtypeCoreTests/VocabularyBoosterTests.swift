import FluidAudio
import Foundation
import Testing
@testable import MouthtypeCore

private final class Counter: Sendable {
    private let value = NSLock()
    nonisolated(unsafe) private var n = 0
    func next() -> Int { value.withLock { n += 1; return n } }
    var count: Int { value.withLock { n } }
}

private struct FakeRescorer: VocabularyRescoring {
    var result: VocabularyRescore?
    var delay: Duration = .zero
    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> VocabularyRescore? {
        if delay > .zero { try? await Task.sleep(for: delay) }
        return result
    }
}

/// Blocks until `released` is bumped, and does not notice cancellation, like FluidAudio's synchronous scoring.
private struct BlockingRescorer: VocabularyRescoring {
    let invocations: Counter
    let released: Counter
    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> VocabularyRescore? {
        _ = invocations.next()
        while released.count == 0 {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
            }
        }
        return VocabularyRescore(text: "hi Maya", wasModified: true, appliedTerms: ["Maya"])
    }
}

private struct Boom: Error, LocalizedError { var errorDescription: String? { "no network" } }

private let timings = [TokenTiming(token: "\u{2581}hi", tokenId: 1, startTime: 0, endTime: 0.2, confidence: 0.9)]
private let samples = [Float](repeating: 0.1, count: 1_600)
private let maya = VocabularyBias(terms: ["Maya"])

@Suite struct VocabularyBoosterTests {
    private func booster(
        result: VocabularyRescore? = VocabularyRescore(text: "hi Maya", wasModified: true, appliedTerms: ["Maya"]),
        delay: Duration = .zero, timeout: Duration = .milliseconds(1500), retryAfter: Duration = .seconds(300),
        builds: Counter = Counter(), failures: Int = 0, releases: Counter = Counter()
    ) -> VocabularyBooster {
        VocabularyBooster(timeout: timeout, retryAfter: retryAfter, prepare: { _, _ in
            if builds.next() <= failures { throw Boom() }
            return FakeRescorer(result: result, delay: delay)
        }, release: { _ = releases.next() }, report: { _ in })
    }

    @Test func usesRescoredTextAndReportsAppliedTerms() async {
        let b = booster()
        await b.setBias(maya)
        await b.waitUntilSettled()
        let boosted = await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples)
        #expect(boosted == BoostedText(text: "hi Maya", appliedTerms: ["Maya"]))
    }

    @Test func sessionIsCachedAndRebuiltOnlyWhenTermsChange() async {
        let builds = Counter()
        let b = booster(builds: builds)
        await b.setBias(maya)
        await b.waitUntilSettled()
        await b.setBias(VocabularyBias(terms: ["Maya"]))
        await b.waitUntilSettled()
        #expect(builds.count == 1)
        await b.setBias(VocabularyBias(terms: ["Maya", "Siobhan"]))
        await b.waitUntilSettled()
        #expect(builds.count == 2)
        #expect(await b.sessionsBuilt == 2)
    }

    @Test func clearingTheBiasReleasesAndStopsBoosting() async {
        let releases = Counter()
        let b = booster(releases: releases)
        await b.setBias(maya)
        await b.waitUntilSettled()
        await b.setBias(nil)
        #expect(releases.count == 1)
        #expect(await b.boost(text: "hi", tokenTimings: timings, samples: samples) == nil)
        await b.setBias(VocabularyBias(terms: []))
        #expect(await b.isReady == false)
    }

    @Test func notReadyMeansUnboostedAndNeverWaitsForTheBuild() async {
        let gate = Counter()
        let b = VocabularyBooster(prepare: { _, _ in
            while gate.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
            return FakeRescorer(result: nil)
        }, report: { _ in })
        await b.setBias(maya)
        #expect(await b.boost(text: "hi", tokenTimings: timings, samples: samples) == nil)
        _ = gate.next()
        await b.waitUntilSettled()
        #expect(await b.isReady)
    }

    @Test func buildFailureFallsBackAndDoesNotRetryUntilTheBiasChanges() async {
        let builds = Counter()
        let b = booster(builds: builds, failures: 1)
        await b.setBias(maya)
        await b.waitUntilSettled()
        #expect(await b.boost(text: "hi", tokenTimings: timings, samples: samples) == nil)
        await b.setBias(maya)
        await b.waitUntilSettled()
        #expect(builds.count == 1)
        await b.setBias(VocabularyBias(terms: ["Maya", "Ana"]))
        await b.waitUntilSettled()
        #expect(builds.count == 2)
        #expect(await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples)?.text == "hi Maya")
    }

    @Test func failedBuildRetriesAfterTheCooldown() async {
        let builds = Counter()
        let b = booster(retryAfter: .zero, builds: builds, failures: 1)
        await b.setBias(maya)
        await b.waitUntilSettled()
        await b.setBias(maya)
        await b.waitUntilSettled()
        #expect(builds.count == 2)
        #expect(await b.isReady)
    }

    @Test func timedOutRescoringIsNotStackedUntilItFinishes() async {
        let invocations = Counter()
        let released = Counter()
        let rescorer = BlockingRescorer(invocations: invocations, released: released)
        let b = VocabularyBooster(timeout: .milliseconds(50), prepare: { _, _ in rescorer }, report: { _ in })
        await b.setBias(maya)
        await b.waitUntilSettled()
        #expect(await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples) == nil)
        #expect(invocations.count == 1)
        #expect(await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples) == nil)
        #expect(invocations.count == 1)
        _ = released.next()
        // The abandoned work clears the marker once it actually returns.
        for _ in 0..<200 where invocations.count == 1 {
            if await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples) != nil { break }
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(invocations.count == 2)
    }

    /// A booster whose build blocks until `gate` is bumped.
    private func gatedBooster(gate: Counter, started: Counter) -> VocabularyBooster {
        VocabularyBooster(prepare: { _, _ in
            _ = started.next()
            while gate.count == 0 {
                await withCheckedContinuation { continuation in
                    DispatchQueue.global().asyncAfter(deadline: .now() + 0.005) { continuation.resume() }
                }
            }
            return FakeRescorer(result: nil)
        }, report: { _ in })
    }

    @Test func setBiasWithoutABudgetReturnsWhileTheBuildIsStillGated() async {
        let gate = Counter()
        let b = gatedBooster(gate: gate, started: Counter())
        await b.setBias(maya)
        #expect(await b.isReady == false)
        _ = gate.next()
        await b.waitUntilSettled()
        #expect(await b.isReady)
    }

    @Test func setBiasWithABudgetWaitsForAFastBuild() async {
        let b = booster()
        await b.setBias(maya, settleWithin: .seconds(5))
        #expect(await b.isReady)
    }

    @Test func setBiasWithABudgetGivesUpOnASlowBuildAndLeavesItRunning() async {
        let gate = Counter()
        let b = gatedBooster(gate: gate, started: Counter())
        await b.setBias(maya, settleWithin: .milliseconds(50))
        #expect(await b.isReady == false)
        _ = gate.next()
        await b.waitUntilSettled()
        #expect(await b.isReady)
    }

    @Test func settleOnAnUnchangedBiasAlreadyBuildingWaitsWithoutRebuilding() async {
        let gate = Counter()
        let started = Counter()
        let b = gatedBooster(gate: gate, started: started)
        await b.setBias(maya)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.05) { _ = gate.next() }
        await b.setBias(maya, settleWithin: .seconds(5))
        #expect(await b.isReady)
        #expect(started.count == 1)
    }

    @Test func settleOnAnUnchangedBiasStillBuildingGivesUpAtTheCap() async {
        let gate = Counter()
        let b = gatedBooster(gate: gate, started: Counter())
        await b.setBias(maya)
        await b.setBias(maya, settleWithin: .milliseconds(50))
        #expect(await b.isReady == false)
        _ = gate.next()
        await b.waitUntilSettled()
        #expect(await b.isReady)
    }

    @Test func rescoringPastTheLimitKeepsTheUnboostedText() async {
        let b = booster(delay: .seconds(5), timeout: .milliseconds(50))
        await b.setBias(maya)
        await b.waitUntilSettled()
        let clock = ContinuousClock()
        let start = clock.now
        let boosted = await b.boost(text: "hi Maia", tokenTimings: timings, samples: samples)
        #expect(boosted == nil)
        #expect(clock.now - start < .seconds(2))
    }

    @Test func rescorerThatChangesNothingOrReturnsNothingKeepsTheText() async {
        for result in [nil, VocabularyRescore(text: "hi", wasModified: false, appliedTerms: []),
                       VocabularyRescore(text: "  ", wasModified: true, appliedTerms: [])] {
            let b = booster(result: result)
            await b.setBias(maya)
            await b.waitUntilSettled()
            #expect(await b.boost(text: "hi", tokenTimings: timings, samples: samples) == nil)
        }
    }

    @Test func termsBecomeFluidAudioVocabularyWithAliases() {
        let context = FluidVocabularyRescorer.context(for: VocabularyBias(entries: [
            VocabularyBias.Term(text: "Sockguard", aliases: ["sock guard"]), VocabularyBias.Term(text: "Maya"),
        ]))
        #expect(context.terms.map(\.text) == ["Sockguard", "Maya"])
        #expect(context.terms[0].aliases == ["sock guard"])
        #expect(context.terms[1].aliases == nil)
        #expect(FluidVocabularyRescorer.rescorerConfig(tuning: .standard).spotterRescueEnabled == false)
    }
}

@Suite struct VocabularyRealignTests {
    private func word(_ text: String, _ start: Double, _ end: Double, _ confidence: Float = 0.9) -> MouthtypeCore.WordTiming {
        MouthtypeCore.WordTiming(word: text, start: start, end: end, confidence: confidence)
    }

    @Test func untouchedWordsKeepTheirTimes() {
        let words = [word("hi", 0, 0.2), word("Maia", 0.2, 0.6, 0.4), word("there", 0.6, 1)]
        let out = VocabularyBooster.realign(words, to: "hi Maya there")
        #expect(out.map(\.word) == ["hi", "Maya", "there"])
        #expect(out[0] == words[0] && out[2] == words[2])
        #expect(out[1].start == 0.2 && out[1].end == 0.6 && out[1].confidence == 0.4)
    }

    @Test func aTwoWordSpanBecomesOneWordCoveringBothTimes() {
        let words = [word("a", 0, 0.1), word("sock", 0.1, 0.4, 0.7), word("guard", 0.4, 0.8, 0.5), word("b", 0.8, 1)]
        let out = VocabularyBooster.realign(words, to: "a Sockguard b")
        #expect(out.map(\.word) == ["a", "Sockguard", "b"])
        #expect(out[1].start == 0.1 && out[1].end == 0.8 && out[1].confidence == 0.5)
    }

    @Test func aOneWordSpanBecomingTwoSharesTheSpanEvenly() {
        let words = [word("a", 0, 0.1), word("sockguard", 0.1, 0.5), word("b", 0.5, 1)]
        let out = VocabularyBooster.realign(words, to: "a sock guard b")
        #expect(out.map(\.word) == ["a", "sock", "guard", "b"])
        #expect(abs(out[1].end - 0.3) < 1e-9 && abs(out[2].start - 0.3) < 1e-9 && out[2].end == 0.5)
    }

    @Test func twoSeparateReplacementsLeaveTheWordsBetweenThemAlone() {
        let words = [word("Maia", 0, 0.3), word("and", 0.3, 0.5), word("Sheevon", 0.5, 1)]
        let out = VocabularyBooster.realign(words, to: "Maya and Siobhan")
        #expect(out[1] == words[1])
        #expect(out[0].start == 0 && out[0].end == 0.3 && out[2].start == 0.5 && out[2].end == 1)
    }

    @Test func punctuationOnAReplacedWordIsGivenBack() {
        #expect(VocabularyBooster.restoringPunctuation(original: "Next to fluid audio.", boosted: "Next to FluidAudio") == "Next to FluidAudio.")
        #expect(VocabularyBooster.restoringPunctuation(original: "Hi, (sock guard), then ok?", boosted: "Hi, Sockguard then ok?") == "Hi, (Sockguard), then ok?")
        #expect(VocabularyBooster.restoringPunctuation(original: "I met Maia.", boosted: "I met Maya.") == "I met Maya.")
        #expect(VocabularyBooster.restoringPunctuation(original: "Hello there.", boosted: "Hello there.") == "Hello there.")
    }

    @Test func adjacentReplacementsKeepTheirOwnPunctuation() {
        #expect(VocabularyBooster.restoringPunctuation(original: "Meet Jon, Sara.", boosted: "Meet John Sarah.") == "Meet John, Sarah.")
        #expect(VocabularyBooster.restoringPunctuation(original: "Meet Jon, Sara.", boosted: "Meet John Sarah") == "Meet John, Sarah.")
        #expect(VocabularyBooster.restoringPunctuation(original: "Jon. Sara called.", boosted: "John Sarah called.") == "John. Sarah called.")
    }

    private var multiWordVocabulary: [VocabularyBooster.KnownTerm] {
        VocabularyBooster.knownTerms(
            bias: VocabularyBias(entries: [
                .init(text: "Sockguard", aliases: ["sock guard"]),
                .init(text: "Open AI", aliases: ["openai"]),
                .init(text: "FluidAudio", aliases: ["fluid audio"]),
            ]),
            replacements: []
        )
    }

    @Test func commaBetweenTwoMultiWordTermsStaysOutsideThem() {
        let out = VocabularyBooster.restoringPunctuation(
            original: "Try sock guard, openai.", boosted: "Try Sockguard Open AI", known: multiWordVocabulary
        )
        #expect(out == "Try Sockguard, Open AI.")
    }

    @Test func commaBeforeAMultiWordOriginalIsKept() {
        let out = VocabularyBooster.restoringPunctuation(
            original: "Meet Jon, fluid audio.", boosted: "Meet John FluidAudio", known: multiWordVocabulary
        )
        #expect(out == "Meet John, FluidAudio.")
    }

    @Test func singleWordReplacementsStillWorkWithAVocabulary() {
        let known = multiWordVocabulary
        #expect(VocabularyBooster.restoringPunctuation(original: "Meet Jon, Sara.", boosted: "Meet John Sarah", known: known) == "Meet John, Sarah.")
        #expect(VocabularyBooster.restoringPunctuation(original: "Jon. Sara called.", boosted: "John Sarah called.", known: known) == "John. Sarah called.")
    }

    @Test func repeatedAliasesFinishQuicklyWithTheUniquePartition() {
        let known = VocabularyBooster.knownTerms(
            bias: VocabularyBias(entries: [.init(text: "GoGo", aliases: ["go", "go go"])]), replacements: []
        )
        let original = Array(repeating: "go", count: 60).joined(separator: " ")
        let boosted = Array(repeating: "GoGo", count: 30).joined(separator: " ")
        let clock = ContinuousClock()
        var out = ""
        let elapsed = clock.measure {
            out = VocabularyBooster.restoringPunctuation(original: original, boosted: boosted, known: known)
        }
        #expect(elapsed < .milliseconds(500))
        #expect(out == boosted)
    }

    @Test func manyOriginalWordsCollapsingToOneTermDropInnerPunctuation() {
        #expect(VocabularyBooster.restoringPunctuation(original: "Hi sock, guard. Ok", boosted: "Hi Sockguard Ok") == "Hi Sockguard. Ok")
        #expect(VocabularyBooster.restoringPunctuation(original: "Hi (fluid, audio), ok", boosted: "Hi FluidAudio ok", known: multiWordVocabulary) == "Hi (FluidAudio), ok")
    }

    @Test func rescorerReplacementsTeachTheMatching() {
        let known = VocabularyBooster.knownTerms(bias: nil, replacements: [
            .init(heard: "sock guard", term: "Sockguard"), .init(heard: "openai", term: "Open AI"),
        ])
        #expect(VocabularyBooster.restoringPunctuation(original: "Try sock guard, openai.", boosted: "Try Sockguard Open AI", known: known) == "Try Sockguard, Open AI.")
    }

    @Test func anAmbiguousSpanKeepsTheOriginalWords() {
        let known = VocabularyBooster.knownTerms(
            bias: VocabularyBias(entries: [
                .init(text: "Xray", aliases: ["foo bar", "foo"]),
                .init(text: "Yankee", aliases: ["baz", "bar baz"]),
            ]),
            replacements: []
        )
        let out = VocabularyBooster.restoringPunctuation(original: "See foo bar, baz.", boosted: "See Xray Yankee", known: known)
        #expect(out == "See foo bar, baz.")
    }

    @Test func noTimingsInMeansNoneOut() {
        #expect(VocabularyBooster.realign([], to: "hi").isEmpty)
    }
}

@Suite struct ModelStoreTests {
    @Test func aLoadFinishingAfterReleaseIsNotCached() async throws {
        let gate = Counter()
        let loads = Counter()
        let store = ModelStore<Int>(loader: { _ in
            let n = loads.next()
            while gate.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
            return n
        })
        let inFlight = Task { try await store.load(report: { _ in }) }
        while loads.count == 0 { try await Task.sleep(for: .milliseconds(5)) }
        await store.release()
        _ = gate.next()
        #expect(try await inFlight.value == 1)
        #expect(await store.isLoaded == false)
        #expect(try await store.load(report: { _ in }) == 2)
        #expect(await store.isLoaded)
    }
}

@Suite(.serialized) struct DependencyLoggingTests {
    @Test func buildingABoosterRaisesFluidAudioLoggingToWarnings() {
        let original = AppLogger.minimumLevel
        defer { AppLogger.minimumLevel = original }
        AppLogger.minimumLevel = .debug
        _ = VocabularyBooster(prepare: { _, _ in FakeRescorer() }, report: { _ in })
        // Debug and info lines carry terms and replacements; "Vocabulary rescoring failed" is a warning and stays.
        #expect(AppLogger.minimumLevel == .warning)
        #expect(AppLogger.minimumLevel <= AppLogger.Level.warning)
    }

    @Test func aStricterLevelIsLeftAlone() {
        let original = AppLogger.minimumLevel
        defer { AppLogger.minimumLevel = original }
        AppLogger.minimumLevel = .fault
        _ = VocabularyBooster(prepare: { _, _ in FakeRescorer() }, report: { _ in })
        #expect(AppLogger.minimumLevel == .fault)
    }

    @Test func sessionBuildsDropTermWarningsThenRestoreTheLevel() async {
        let original = AppLogger.minimumLevel
        defer { AppLogger.minimumLevel = original }
        AppLogger.minimumLevel = .warning
        let during = await DependencyLogging.quietingWarnings { AppLogger.minimumLevel }
        #expect(during == .error)
        #expect(AppLogger.minimumLevel == .warning)
    }

    @Test func aThrowingBuildStillRestoresTheLevel() async {
        let original = AppLogger.minimumLevel
        defer { AppLogger.minimumLevel = original }
        AppLogger.minimumLevel = .warning
        _ = try? await DependencyLogging.quietingWarnings { throw Boom() }
        #expect(AppLogger.minimumLevel == .warning)
    }

    @Test func overlappingBuildsRestoreOnlyWhenTheLastFinishes() async {
        let original = AppLogger.minimumLevel
        defer { AppLogger.minimumLevel = original }
        AppLogger.minimumLevel = .warning
        await DependencyLogging.quietingWarnings {
            await DependencyLogging.quietingWarnings {}
            #expect(AppLogger.minimumLevel == .error)
        }
        #expect(AppLogger.minimumLevel == .warning)
    }
}
