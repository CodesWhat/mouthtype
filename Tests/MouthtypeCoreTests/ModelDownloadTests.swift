import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct ModelDownloadTests {
    // MARK: Rate smoothing

    @Test func noEstimateUntilTheWindowSpansEnoughTime() {
        var meter = DownloadRateMeter()
        meter.record(fraction: 0.1, at: 0)
        #expect(meter.secondsRemaining == nil)
        meter.record(fraction: 0.12, at: 0.5)
        #expect(meter.secondsRemaining == nil)
    }

    @Test func estimateIsTheWindowAverageNotTheLastBurst() throws {
        var meter = DownloadRateMeter(window: 6, minimumSpan: 1.5)
        // 10% per second for five seconds, then a burst that would read as 50% per second on its own.
        for second in 0...5 { meter.record(fraction: Double(second) * 0.1, at: Double(second)) }
        meter.record(fraction: 0.55, at: 5.1)
        let remaining = try #require(meter.secondsRemaining)
        // Window average: (0.55 - 0) / 5.1 = ~0.108 per second, so ~4.2 s left. The burst alone would say under 1 s.
        #expect(abs(remaining - 0.45 / (0.55 / 5.1)) < 0.001)
        #expect(remaining > 4)
    }

    @Test func oldSamplesLeaveTheWindowSoASlowdownShowsUp() throws {
        var meter = DownloadRateMeter(window: 4, minimumSpan: 1)
        for second in 0...4 { meter.record(fraction: Double(second) * 0.2, at: Double(second)) }
        let fast = try #require(meter.secondsRemaining)
        for second in 5...12 { meter.record(fraction: 0.8 + Double(second - 4) * 0.01, at: Double(second)) }
        let slow = try #require(meter.secondsRemaining)
        #expect(slow > fast * 5)
    }

    @Test func aStalledOrBackwardsFractionGivesNoEstimateAndNeverNegativeSpeed() {
        var meter = DownloadRateMeter(window: 6, minimumSpan: 1)
        meter.record(fraction: 0.5, at: 0)
        meter.record(fraction: 0.5, at: 3)
        #expect(meter.secondsRemaining == nil)
        meter.record(fraction: 0.2, at: 4)
        #expect(meter.fractionPerSecond == nil)
        meter.reset()
        #expect(meter.secondsRemaining == nil)
    }

    // MARK: Progress sources

    @Test func fractionOnlyProgressUsesTheKnownTotalForBytes() {
        let progress = ModelDownloadProgress(fraction: 0.25, knownTotalBytes: 400_000_000)
        #expect(progress.completedBytes == 100_000_000)
        #expect(progress.fraction == 0.25)
        #expect(ModelDownloadFormat.caption(progress) == "100 of 400 MB")
    }

    @Test func fractionIsClampedAndNonFiniteIsZero() {
        #expect(ModelDownloadProgress(fraction: 3).fraction == 1)
        #expect(ModelDownloadProgress(fraction: -1).fraction == 0)
        #expect(ModelDownloadProgress(fraction: .nan).fraction == 0)
    }

    @Test func hubUnitsAreBytesWhenTheTreeDeclaredSizes() {
        let progress = ModelDownloadProgress(hubCompletedUnits: 1_500_000_000, hubTotalUnits: 5_000_000_000, knownTotalBytes: 5_150_000_000)
        #expect(progress.usesBytes)
        #expect(progress.totalBytes == 5_000_000_000)
        #expect(abs(progress.fraction - 0.3) < 1e-9)
        #expect(ModelDownloadFormat.caption(progress) == "1.5 of 5.0 GB")
    }

    @Test func hubFileCountsFallBackToAFileBarSizedFromTheCatalog() {
        // No sizes in the tree: every file weighs one unit, so 3 of 12 units is 3 of 12 files.
        let progress = ModelDownloadProgress(hubCompletedUnits: 3, hubTotalUnits: 12, knownTotalBytes: 1_447_000_000)
        #expect(!progress.usesBytes)
        #expect(progress.completedFiles == 3 && progress.totalFiles == 12)
        #expect(progress.fraction == 0.25)
        #expect(progress.displayTotalBytes == 1_447_000_000)
        #expect(ModelDownloadFormat.caption(progress) == "0.4 of 1.4 GB")
    }

    @Test func fileCountsAloneStillShowAFileCaption() {
        let progress = ModelDownloadProgress(hubCompletedUnits: 2, hubTotalUnits: 5)
        #expect(progress.fraction == 0.4)
        #expect(ModelDownloadFormat.caption(progress) == "2 of 5 files")
    }

    @Test func hubProgressBeforeAnyUnitsIsZeroNotNaN() {
        let progress = ModelDownloadProgress(hubCompletedUnits: 0, hubTotalUnits: 0)
        #expect(progress.fraction == 0)
        #expect(ModelDownloadFormat.caption(progress) == "0%")
    }

    // MARK: Staged FluidAudio reports

    @Test func stagedReportsNeverRestartWhenTheNextModelBegins() {
        var tracker = StagedDownloadTracker(stageBytes: [1_000, 9_000])
        #expect(tracker.initial.totalBytes == 10_000 && tracker.initial.completedBytes == 0)
        var last: Int64 = 0
        func step(_ fraction: Double, _ event: StagedDownloadTracker.Event) -> ModelDownloadProgress {
            let progress = tracker.update(fraction: fraction, event: event)
            #expect(progress.completedBytes >= last, "bar moved back at \(event) \(fraction)")
            last = progress.completedBytes
            return progress
        }
        _ = step(0, .listing)
        #expect(step(0.25, .downloading).completedBytes == 500)   // half of stage 1's download half
        #expect(step(0.5, .downloading).completedBytes == 1_000)
        #expect(step(0.75, .compiling).completedBytes == 1_000)   // compiling adds no bytes
        #expect(step(1, .finished).completedBytes == 1_000)
        #expect(tracker.stage == 1 && !tracker.isComplete)
        #expect(step(0, .listing).completedBytes == 1_000)        // FluidAudio's fraction restarts for the encoder
        #expect(step(0.25, .downloading).completedBytes == 1_000 + 4_500)
        let done = step(1, .finished)
        #expect(done.completedBytes == 10_000 && done.fraction == 1)
        #expect(tracker.isComplete)
        #expect(done.completedFiles == 2 && done.totalFiles == 2)
    }

    @Test func aCachedModelCountsAsDownloadedAtOnce() {
        var tracker = StagedDownloadTracker(stageBytes: [100, 900])
        // FluidAudio's cached path reports the download half as complete with no files.
        #expect(tracker.update(fraction: 0.5, event: .downloading).completedBytes == 100)
        #expect(tracker.update(fraction: 1, event: .finished).completedBytes == 100)
        #expect(tracker.stage == 1)
    }

    @Test func aLateOutOfOrderReportCannotLowerTheBar() {
        var tracker = StagedDownloadTracker(stageBytes: [1_000])
        #expect(tracker.update(fraction: 0.4, event: .downloading).completedBytes == 800)
        #expect(tracker.update(fraction: 0.1, event: .downloading).completedBytes == 800)
    }

    // MARK: Done and failed states

    @Test func statusFractionIsFullWhenDoneAndEmptyWhenAvailableOrFailed() {
        #expect(ModelDownloadStatus.done.fraction == 1)
        #expect(ModelDownloadStatus.available.fraction == 0)
        #expect(ModelDownloadStatus.failed(message: "offline").fraction == 0)
        #expect(ModelDownloadStatus.downloading(ModelDownloadProgress(fraction: 0.4)).fraction == 0.4)
        #expect(ModelDownloadStatus.failed(message: "offline") != .failed(message: "disk full"))
    }

    // MARK: Formatting

    @Test func remainingTimeReadsInTheRightUnit() {
        #expect(ModelDownloadFormat.remaining(4) == "a few seconds left")
        #expect(ModelDownloadFormat.remaining(42) == "about 40 seconds left")
        #expect(ModelDownloadFormat.remaining(61) == "about 2 min left")
        #expect(ModelDownloadFormat.remaining(600) == "about 10 min left")
        #expect(ModelDownloadFormat.remaining(3_600) == "about 1 hr left")
        #expect(ModelDownloadFormat.remaining(5_400) == "about 1 hr 30 min left")
        #expect(ModelDownloadFormat.remaining(.infinity) == "")
    }

    @Test func captionJoinsSizeAndTimeRemaining() {
        var progress = ModelDownloadProgress(fraction: 0.5, knownTotalBytes: 483_000_000)
        progress.secondsRemaining = 95
        #expect(ModelDownloadFormat.caption(progress) == "242 of 483 MB, about 2 min left")
        #expect(ModelDownloadFormat.size(1_447_000_000) == "1.4 GB")
        #expect(ModelDownloadFormat.size(483_000_000) == "483 MB")
    }
}
