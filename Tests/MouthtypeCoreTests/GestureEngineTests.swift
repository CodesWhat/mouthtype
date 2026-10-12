import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct GestureEngineTests {
    private func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }
    private let fnDown = KeyEvent(key: nil, modifiers: [.fn])
    private let fnUp = KeyEvent(key: nil, modifiers: [])

    @Test func defaultsAreFnAlone300msNoDoubleTapLock() {
        let configuration = GestureConfiguration.default
        #expect(configuration.hotkey == HotKey(key: nil, modifiers: [.fn]))
        #expect(configuration.minimumKeyTime == 0.3)
        #expect(!configuration.doubleTapLockEnabled)
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
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.process(fnUp, now: at(0.1)) == .discarded(.tooShort))
        #expect(engine.process(fnDown, now: at(0.2)) == .pressed)
        #expect(engine.process(fnUp, now: at(0.3)) == .discarded(.tooShort))
        #expect(!engine.isRecording)
    }

    @Test func doubleTapLockIsReachableByFlag() {
        var engine = GestureEngine(configuration: GestureConfiguration(doubleTapLockEnabled: true))
        _ = engine.process(fnDown, now: at(0))
        _ = engine.process(fnUp, now: at(0.1))
        _ = engine.process(fnDown, now: at(0.2))
        #expect(engine.process(fnUp, now: at(0.3)) == nil)
        #expect(engine.isRecording)
        #expect(engine.process(fnDown, now: at(5)) == .released)
    }

    @Test func mouseClickEarlyDiscards() {
        var engine = GestureEngine()
        _ = engine.process(fnDown, now: at(0))
        #expect(engine.processMouseClick(now: at(0.1)) == .discarded(.otherInput))
    }
}
