import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct GestureEngineTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    private let fnDown = KeyEvent(key: nil, modifiers: [.fn])
    private let fnUp = KeyEvent(key: nil, modifiers: [])

    @Test func defaultsAreFnAlone300msWithDoubleTapLock() {
        let configuration = GestureConfiguration.default
        #expect(configuration.hotkey == HotKey(key: nil, modifiers: [.fn]))
        #expect(configuration.minimumKeyTime == 0.3)
        #expect(configuration.doubleTapLockEnabled)
    }

    private func lockedEngine() -> GestureEngine {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        _ = engine.process(fnUp, now: at(0.1))
        _ = engine.process(fnDown, now: at(0.2))
        _ = engine.process(fnUp, now: at(0.3))
        return engine
    }

    @Test func pressIsReportedAtOnceAndLongHoldReleases() {
        var engine = GestureEngine()
        #expect(engine.process(fnDown, now: at(0)) == .pressed)
        #expect(engine.isRecording)
        #expect(engine.process(fnUp, now: at(1)) == .released)
        #expect(!engine.isRecording)
    }

    @Test func shortTapIsJudgedAtReleaseAndDiscarded() {
        var engine = GestureEngine()
        #expect(engine.process(fnDown, now: at(0)) == .pressed)
        #expect(engine.process(fnUp, now: at(0.2)) == .discarded(.tooShort))
    }

    @Test func holdOfExactlyTheMinimumIsKept() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(fnUp, now: at(0.3)) == .released)
    }

    @Test func otherKeyEarlyDiscardsSilently() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(KeyEvent(key: .a, modifiers: [.fn]), now: at(0.1)) == .discarded(.otherInput))
        #expect(!engine.isRecording)
        // Dirty until a full release, so the Fn-up that follows says nothing.
        #expect(engine.process(fnUp, now: at(0.5)) == nil)
    }

    @Test func otherKeyAfterTheMinimumKeepsRecording() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(KeyEvent(key: .a, modifiers: [.fn]), now: at(0.5)) == nil)
        #expect(engine.isRecording)
        #expect(engine.process(fnUp, now: at(1)) == .released)
    }

    @Test func escapeCancelsAnActiveRecordingOnly() {
        var engine = GestureEngine()
        #expect(engine.process(KeyEvent(key: .escape, modifiers: []), now: at(0)) == nil)
        // Esc made the chord dirty; a full release clears it.
        _ = engine.process(fnUp, now: at(0.5))
        _ = engine.process(fnDown, now: at(1))
        #expect(engine.process(KeyEvent(key: .escape, modifiers: [.fn]), now: at(1.5)) == .cancelled(.escape))
    }

    @Test func secondQuickTapDoesNotLockWhileDoubleTapLockIsOff() {
        var engine = GestureEngine(configuration: GestureConfiguration(doubleTapLockEnabled: false))
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(fnUp, now: at(0.1)) == .discarded(.tooShort))
        #expect(engine.process(fnDown, now: at(0.2)) == .pressed)
        #expect(engine.process(fnUp, now: at(0.3)) == .discarded(.tooShort))
        #expect(!engine.isRecording)
    }

    @Test func doubleTapEngagesTheLockOnTheSecondRelease() {
        var engine = GestureEngine()
        #expect(engine.process(fnDown, now: at(0)) == .pressed)
        #expect(engine.process(fnUp, now: at(0.1)) == .discarded(.tooShort))
        #expect(engine.process(fnDown, now: at(0.2)) == .pressed)
        #expect(engine.isRecording && !engine.isLocked)
        #expect(engine.process(fnUp, now: at(0.3)) == .locked(.doubleTap))
        #expect(engine.isRecording && engine.isLocked)
    }

    @Test func tapWhileLockedStopsAndTranscribesEvenIfBrief() {
        var engine = lockedEngine()
        #expect(engine.process(fnDown, now: at(0.4)) == .released)
        #expect(!engine.isRecording && !engine.isLocked)
        // The release that follows the stopping press says nothing.
        #expect(engine.process(fnUp, now: at(0.45)) == nil)
    }

    @Test func escapeWhileLockedCancels() {
        var engine = lockedEngine()
        #expect(engine.process(KeyEvent(key: .escape, modifiers: []), now: at(5)) == .cancelled(.escape))
        #expect(!engine.isRecording && !engine.isLocked)
    }

    @Test func slowSecondTapOutsideTheWindowDoesNotLock() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        _ = engine.process(fnUp, now: at(0.1))
        _ = engine.process(fnDown, now: at(0.45))
        #expect(engine.process(fnUp, now: at(0.55)) == .discarded(.tooShort))
        #expect(!engine.isRecording)
    }

    @Test func holdStillWorksWithLockEnabled() {
        var engine = GestureEngine()
        #expect(engine.process(fnDown, now: at(0)) == .pressed)
        #expect(engine.process(fnUp, now: at(1.5)) == .released)
        #expect(!engine.isLocked)
    }

    @Test func aQuickTapRightAfterARealHoldDoesNotLock() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(fnUp, now: at(1)) == .released)
        _ = engine.process(fnDown, now: at(1.1))
        #expect(engine.process(fnUp, now: at(1.2)) == .discarded(.tooShort))
        #expect(!engine.isRecording)
    }

    @Test func lockedStopCanLockAgainLater() {
        var engine = lockedEngine()
        _ = engine.process(fnDown, now: at(0.4))
        _ = engine.process(fnUp, now: at(0.45))
        _ = engine.process(fnDown, now: at(10))
        _ = engine.process(fnUp, now: at(10.1))
        _ = engine.process(fnDown, now: at(10.2))
        #expect(engine.process(fnUp, now: at(10.3)) == .locked(.doubleTap))
    }

    @Test func chordLockTurnsTheHoldIntoALock() {
        var engine = GestureEngine()
        #expect(engine.lockFromChord() == nil)
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.lockFromChord() == .locked(.fnSpace))
        #expect(engine.isLocked)
        // Releasing the key afterwards leaves the recording open.
        #expect(engine.process(fnUp, now: at(0.05)) == nil)
        #expect(engine.isRecording)
        #expect(engine.process(fnDown, now: at(3)) == .released)
        #expect(!engine.isRecording)
    }

    @Test func endLockFromOutsideReturnsToIdle() {
        var engine = lockedEngine()
        engine.endLock()
        #expect(!engine.isRecording && !engine.isLocked)
        #expect(engine.process(fnUp, now: at(1)) == nil)
        #expect(engine.process(fnDown, now: at(2)) == .pressed)
    }

    @Test func otherKeyWhileLockedIsIgnoredByTheProcessorUntilFullRelease() {
        var engine = lockedEngine()
        #expect(engine.process(KeyEvent(key: .a, modifiers: []), now: at(1)) == nil)
        #expect(engine.isLocked)
    }

    @Test func mouseClickEarlyDiscards() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.processMouseClick(now: at(0.1)) == .discarded(.otherInput))
    }
}
