import CoreGraphics
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@Suite struct HotkeyInputMapperTests {
    static let fn = CGEventFlags.maskSecondaryFn.rawValue
    static let shift = CGEventFlags.maskShift.rawValue
    static let command = CGEventFlags.maskCommand.rawValue

    private func flags(_ keyCode: UInt16, _ flags: UInt64, at time: UInt64) -> TapSample {
        TapSample(kind: .flagsChanged, keyCode: keyCode, flags: flags, timestamp: time)
    }

    private func key(_ kind: TapSample.Kind, _ keyCode: UInt16, flags: UInt64 = 0, at time: UInt64, userData: Int64 = 0, autorepeat: Bool = false) -> TapSample {
        TapSample(kind: kind, keyCode: keyCode, flags: flags, timestamp: time, userData: userData, isAutorepeat: autorepeat)
    }

    /// Runs samples through the mapper and the gesture engine the way the service does. Host time stands in for seconds.
    private func run(
        _ samples: [TapSample],
        source: HotkeySource = .fnFlag,
        otherKeysHeld: Bool = false
    ) -> [GestureEvent] {
        var mapper = HotkeyInputMapper(source: source)
        var engine = GestureEngine()
        var events: [GestureEvent] = []
        for sample in samples {
            guard let mapped = mapper.map(sample, otherKeysHeld: { otherKeysHeld }) else { continue }
            let now = Date(timeIntervalSinceReferenceDate: Double(mapped.timestampNanos) / 1000)
            if let event = engine.process(mapped.keyEvent, now: now) { events.append(event) }
            mapper.lockedRecording = engine.isLocked
        }
        return events
    }

    @Test func fnDownAndUpMapToPressAndRelease() {
        let events = run([flags(63, Self.fn, at: 0), flags(63, 0, at: 1000)])
        #expect(events == [.pressed, .released])
    }

    @Test func pressCarriesTheTapTimestamp() {
        var mapper = HotkeyInputMapper()
        let mapped = mapper.map(flags(63, Self.fn, at: 123_456), otherKeysHeld: { false })
        #expect(mapped?.timestampNanos == 123_456)
        #expect(mapped?.keyEvent == KeyEvent(key: nil, modifiers: [.fn]))
    }

    @Test func shortTapIsDiscardedAtRelease() {
        #expect(run([flags(63, Self.fn, at: 0), flags(63, 0, at: 100)]) == [.pressed, .discarded(.tooShort)])
    }

    @Test func otherKeyEarlyInTheHoldDiscardsAndStaysQuiet() {
        let events = run([
            flags(63, Self.fn, at: 0),
            key(.keyDown, 0, flags: Self.fn, at: 100),
            flags(63, 0, at: 900),
        ])
        #expect(events == [.pressed, .discarded(.otherInput)])
    }

    @Test func otherKeyAfterTheMinimumKeepsRecording() {
        let events = run([
            flags(63, Self.fn, at: 0),
            key(.keyDown, 0, flags: Self.fn, at: 500),
            key(.keyUp, 0, flags: Self.fn, at: 600),
            flags(63, 0, at: 1000),
        ])
        #expect(events == [.pressed, .released])
    }

    @Test func escapeCancels() {
        let events = run([flags(63, Self.fn, at: 0), key(.keyDown, 53, flags: Self.fn, at: 500)])
        #expect(events == [.pressed, .cancelled(.escape)])
    }

    @Test func syntheticKeyDown179OnFnReleaseIsIgnored() {
        var mapper = HotkeyInputMapper()
        _ = mapper.map(flags(63, Self.fn, at: 0), otherKeysHeld: { false })
        #expect(mapper.map(key(.keyDown, 179, at: 100), otherKeysHeld: { false }) == nil)
        // It must not have counted as a chord: the recording still ends normally.
        let events = run([
            flags(63, Self.fn, at: 0),
            key(.keyDown, 179, at: 100),
            key(.keyDown, 179, at: 500),
            flags(63, 0, at: 1000),
        ])
        #expect(events == [.pressed, .released])
    }

    @Test func ownStampedEventsNeverCountAsAChord() {
        let stamp = SyntheticEvents.stamp
        let events = run([
            flags(63, Self.fn, at: 0),
            key(.keyDown, 9, flags: Self.command, at: 100, userData: stamp),
            key(.keyUp, 9, flags: Self.command, at: 120, userData: stamp),
            flags(63, 0, at: 1000),
        ])
        #expect(events == [.pressed, .released])
    }

    @Test func ownStampedModifierChangeIsIgnoredToo() {
        var mapper = HotkeyInputMapper()
        let sample = TapSample(kind: .flagsChanged, keyCode: 63, flags: Self.fn, timestamp: 0, userData: SyntheticEvents.stamp)
        #expect(mapper.map(sample, otherKeysHeld: { false }) == nil)
        #expect(!mapper.hotkeyHeld)
    }

    @Test func pressIsRefusedWhileAnotherKeyIsHeld() {
        let events = run([flags(63, Self.fn, at: 0), flags(63, 0, at: 1000)], otherKeysHeld: true)
        #expect(events.isEmpty)
    }

    @Test func pressIsRefusedWhileAnotherModifierIsHeld() {
        let events = run([
            flags(56, Self.shift, at: 0),
            flags(63, Self.shift | Self.fn, at: 100),
            flags(63, Self.shift, at: 1000),
            flags(56, 0, at: 1100),
        ])
        #expect(events.isEmpty)
    }

    @Test func pressIsRefusedForAModifierTheTrackerNeverSaw() {
        // Shift was down before the app started, so only the event's own flags say so.
        let events = run([flags(63, Self.shift | Self.fn, at: 0), flags(63, Self.shift, at: 1000)])
        #expect(events.isEmpty)
    }

    @Test func refusalClearsOnFullReleaseSoTheNextPressWorks() {
        let events =
            run(
                [
                    flags(63, Self.fn, at: 0), flags(63, 0, at: 1000),
                ], otherKeysHeld: true)
            + run([
                flags(63, Self.fn, at: 2000), flags(63, 0, at: 3000),
            ])
        #expect(events == [.pressed, .released])
    }

    @Test func otherModifierAddedEarlyDiscards() {
        let events = run([
            flags(63, Self.fn, at: 0),
            flags(56, Self.fn | Self.shift, at: 100),
            flags(56, Self.fn, at: 200),
            flags(63, 0, at: 900),
        ])
        #expect(events == [.pressed, .discarded(.otherInput)])
    }

    @Test func keysTypedWhileTheHotkeyIsUpNeverDirtyTheProcessor() {
        let events = run([
            key(.keyDown, 0, at: 0),
            key(.keyUp, 0, at: 50),
            flags(63, Self.fn, at: 100),
            flags(63, 0, at: 1000),
        ])
        #expect(events == [.pressed, .released])
    }

    @Test func arrowKeyFlagsDoNotSetFn() {
        // Arrow keys carry the fn flag even when fn isn't held. Only flagsChanged may set fn.
        var mapper = HotkeyInputMapper()
        _ = mapper.map(key(.keyDown, 123, flags: Self.fn, at: 0), otherKeysHeld: { false })
        #expect(!mapper.hotkeyHeld)
    }

    @Test func autorepeatKeyDownsAreIgnored() {
        var mapper = HotkeyInputMapper()
        _ = mapper.map(flags(63, Self.fn, at: 0), otherKeysHeld: { false })
        #expect(mapper.map(key(.keyDown, 0, flags: Self.fn, at: 100, autorepeat: true), otherKeysHeld: { false }) == nil)
    }

    // MARK: Remap source

    private let f19: UInt16 = 80

    @Test func remappedKeyDownAndUpMapToPressAndRelease() {
        let events = run([key(.keyDown, f19, at: 0), key(.keyUp, f19, at: 1000)], source: .remapped(keyCode: f19))
        #expect(events == [.pressed, .released])
    }

    @Test func remappedKeyRepeatsAreIgnored() {
        let events = run(
            [
                key(.keyDown, f19, at: 0),
                key(.keyDown, f19, at: 400, autorepeat: true),
                key(.keyDown, f19, at: 500),
                key(.keyUp, f19, at: 1000),
            ], source: .remapped(keyCode: f19))
        #expect(events == [.pressed, .released])
    }

    @Test func remappedModeIgnoresTheRealFnFlag() {
        let events = run([flags(63, Self.fn, at: 0), flags(63, 0, at: 1000)], source: .remapped(keyCode: f19))
        #expect(events.isEmpty)
    }

    @Test func remappedModeChordsStillDiscard() {
        let events = run(
            [
                key(.keyDown, f19, at: 0),
                key(.keyDown, 0, at: 100),
                key(.keyUp, f19, at: 900),
            ], source: .remapped(keyCode: f19))
        #expect(events == [.pressed, .discarded(.otherInput)])
    }

    // MARK: Hands-free

    @Test func doubleTapLocksAndAnotherTapStops() {
        let events = run([
            flags(63, Self.fn, at: 0), flags(63, 0, at: 100),
            flags(63, Self.fn, at: 200), flags(63, 0, at: 300),
            flags(63, Self.fn, at: 5000), flags(63, 0, at: 5100),
        ])
        #expect(events == [.pressed, .discarded(.tooShort), .pressed, .locked(.doubleTap), .released])
    }

    @Test func doubleTapLocksInRemapModeToo() {
        let source = HotkeySource.remapped(keyCode: 80)
        let events = run(
            [
                key(.keyDown, 80, at: 0), key(.keyUp, 80, at: 100),
                key(.keyDown, 80, at: 200), key(.keyUp, 80, at: 300),
                key(.keyDown, 80, at: 5000), key(.keyUp, 80, at: 5100),
            ], source: source)
        #expect(events == [.pressed, .discarded(.tooShort), .pressed, .locked(.doubleTap), .released])
    }

    @Test func escapeReachesTheProcessorOnlyWhileLocked() {
        var mapper = HotkeyInputMapper(source: .fnFlag)
        let escape = key(.keyDown, 53, at: 10)
        #expect(mapper.map(escape, otherKeysHeld: { false }) == nil)
        mapper.lockedRecording = true
        #expect(mapper.map(escape, otherKeysHeld: { false })?.keyEvent.key == .escape)
        // Ordinary typing during a lock is none of the processor's business, or it would stop a later tap from ending it.
        #expect(mapper.map(key(.keyDown, 0, at: 20), otherKeysHeld: { false }) == nil)
    }

    @Test func escapeCancelsALockedRecording() {
        var mapper = HotkeyInputMapper(source: .fnFlag)
        var engine = GestureEngine()
        var events: [GestureEvent] = []
        for sample in [
            flags(63, Self.fn, at: 0), flags(63, 0, at: 100), flags(63, Self.fn, at: 200), flags(63, 0, at: 300),
            key(.keyDown, 0, at: 400), key(.keyDown, 53, at: 500), key(.keyUp, 53, at: 600),
            flags(63, Self.fn, at: 2000), flags(63, 0, at: 3000),
        ] {
            mapper.lockedRecording = engine.isLocked
            guard let mapped = mapper.map(sample, otherKeysHeld: { false }) else { continue }
            let now = Date(timeIntervalSinceReferenceDate: Double(mapped.timestampNanos) / 1000)
            if let event = engine.process(mapped.keyEvent, now: now) { events.append(event) }
        }
        #expect(events == [.pressed, .discarded(.tooShort), .pressed, .locked(.doubleTap), .cancelled(.escape), .pressed, .released])
    }
}

@Suite struct ModifierStateTests {
    @Test func leftAndRightShiftStayDistinct() {
        var state = ModifierState()
        let shift = CGEventFlags.maskShift.rawValue
        state.apply(keyCode: 56, flags: shift)
        state.apply(keyCode: 60, flags: shift)
        #expect(state.modifiers == [Modifier(kind: .shift, side: .left), Modifier(kind: .shift, side: .right)])
        // The flag stays set while the right side is still down.
        state.apply(keyCode: 56, flags: shift)
        #expect(state.modifiers == [Modifier(kind: .shift, side: .right)])
        state.apply(keyCode: 60, flags: 0)
        #expect(state.modifiers.isEmpty)
    }

    @Test func aClearFlagRepairsAMissedRelease() {
        var state = ModifierState()
        state.apply(keyCode: 55, flags: CGEventFlags.maskCommand.rawValue)
        let command = CGEventFlags.maskCommand.rawValue
        state.apply(keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue | command)
        #expect(state.held == [55, 63])
        // The command release was never seen; the next event's flags show it is up.
        state.apply(keyCode: 63, flags: 0)
        #expect(state.held.isEmpty)
    }

    @Test func fnCanBeLeftUntracked() {
        var state = ModifierState()
        state.apply(keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue, tracksFn: false)
        #expect(!state.fnHeld)
    }
}
