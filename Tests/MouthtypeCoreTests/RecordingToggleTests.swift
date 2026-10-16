import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct RecordingToggleTests {
    private let down = KeyEvent(key: nil, modifiers: [.fn])
    private let up = KeyEvent(key: nil, modifiers: [])
    private func at(_ seconds: Double) -> Date { Date(timeIntervalSinceReferenceDate: seconds) }

    @Test func singlePressStartsReleaseKeepsRecordingNextPressStopsOnce() {
        var engine = GestureEngine(configuration: .init(recordingMode: .toggle))
        #expect(!engine.isRecording)
        #expect(engine.process(down, now: at(0)) == .pressed)
        #expect(engine.isLocked)
        #expect(engine.process(down, now: at(0.01)) == nil)
        #expect(engine.process(up, now: at(0.05)) == nil)
        #expect(engine.isRecording)
        #expect(engine.process(down, now: at(0.1)) == .released)
        #expect(!engine.isRecording)
        #expect(engine.process(down, now: at(0.11)) == nil)
        #expect(engine.process(up, now: at(0.15)) == nil)
        #expect(engine.process(down, now: at(0.2)) == .pressed)
    }

    @Test func typingAndClickingWhileLockedDoNotBlockTheNextToggle() {
        var engine = GestureEngine(configuration: .init(recordingMode: .toggle))
        _ = engine.process(down, now: at(0))
        #expect(engine.process(KeyEvent(key: .a, modifiers: [.fn]), now: at(0.01)) == nil)
        #expect(engine.process(down, now: at(0.02)) == nil)
        #expect(engine.processMouseClick(now: at(0.03)) == nil)
        _ = engine.process(up, now: at(0.05))
        #expect(engine.process(KeyEvent(key: .a, modifiers: []), now: at(0.1)) == nil)
        #expect(engine.process(down, now: at(1)) == .released)
    }

    @Test func escapeCancelsAndNeedsReleaseBeforeRestart() {
        var engine = GestureEngine(configuration: .init(recordingMode: .toggle))
        _ = engine.process(down, now: at(0))
        #expect(engine.process(KeyEvent(key: .escape, modifiers: [.fn]), now: at(0.1)) == .cancelled(.escape))
        #expect(!engine.isRecording)
        #expect(engine.process(down, now: at(0.2)) == nil)
        _ = engine.process(up, now: at(0.3))
        #expect(engine.process(down, now: at(0.4)) == .pressed)
    }

    @Test func unrelatedChordCannotBackslideIntoStartingRecording() {
        var engine = GestureEngine(configuration: .init(recordingMode: .toggle))
        #expect(engine.process(KeyEvent(key: .a, modifiers: [.fn]), now: at(0)) == nil)
        #expect(engine.process(down, now: at(0.1)) == nil)
        _ = engine.process(up, now: at(0.2))
        #expect(engine.process(down, now: at(0.3)) == .pressed)
    }

    @Test func menuStopAndFailedStartCanReleaseLockWithoutAccidentalRestart() {
        var engine = GestureEngine(configuration: .init(recordingMode: .toggle))
        _ = engine.process(down, now: at(0))
        engine.endLock()
        #expect(!engine.isRecording)
        #expect(engine.process(down, now: at(0.1)) == nil)
        _ = engine.process(up, now: at(0.2))
        #expect(engine.process(down, now: at(1)) == .pressed)
    }

    @Test func defaultModeStillRequiresHoldAndUsesExistingShortTakeDecision() {
        #expect(GestureConfiguration.default.recordingMode == .hold)
        var engine = GestureEngine()
        #expect(engine.process(down, now: at(0)) == .pressed)
        #expect(!engine.isLocked)
        #expect(engine.process(up, now: at(0.1)) == .discarded(.tooShort))
    }

    @Test func keyChordCanToggleAgainWithoutReleasingItsModifier() {
        let chord = KeyEvent(key: .a, modifiers: [.control])
        var engine = GestureEngine(configuration: .init(hotkey: HotKey(key: .a, modifiers: [.control]), recordingMode: .toggle))
        #expect(engine.process(chord, now: at(0)) == .pressed)
        #expect(engine.process(KeyEvent(key: nil, modifiers: [.control]), now: at(0.1)) == nil)
        #expect(engine.process(chord, now: at(0.2)) == .released)
    }
}
