import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct TapPolicyTests {
    private func sample(_ kind: TapSample.Kind, _ keyCode: UInt16, userData: Int64 = 0) -> TapSample {
        TapSample(kind: kind, keyCode: keyCode, flags: 0, timestamp: 0, userData: userData)
    }

    @MainActor @Test(arguments: [UInt16(80), 96])
    func passiveListenerUsesTheConfiguredDictationKeyInsteadOfCountingItAsTyping(key: UInt16) {
        let service = HotkeyService(options: .init(source: .remapped(keyCode: key)), otherKeysHeld: { _ in false })
        let passive = service.tapContext(for: .flags)
        service.shared.inputTracked.store(true, ordering: .relaxed)
        #expect(passive.swallowedKey == key)
        passive.countPassiveKey(sample(.keyDown, key))
        #expect(service.userInputGeneration == 0)
        passive.countPassiveKey(sample(.keyDown, 36))
        #expect(service.userInputGeneration == 1)
    }

    @MainActor @Test func nativeFnFlagsAndSyntheticReleaseDoNotCountButAnUnmappedFunctionKeyDoes() {
        let service = HotkeyService(options: .init(source: .fnFlag), otherKeysHeld: { _ in false })
        let passive = service.tapContext(for: .flags)
        service.shared.inputTracked.store(true, ordering: .relaxed)
        passive.countPassiveKey(sample(.flagsChanged, 63))
        passive.countPassiveKey(sample(.keyDown, 179))
        passive.countPassiveKey(sample(.keyDown, 9, userData: SyntheticEvents.stamp))
        #expect(service.userInputGeneration == 0)
        passive.countPassiveKey(sample(.keyDown, 80))
        #expect(service.userInputGeneration == 1)
    }

    @Test func ordinaryKeyDownsCountAsUserInput() {
        let down = sample(.keyDown, 36)
        #expect(TapPolicy.countsAsUserInput(down, decision: .passThrough, swallowedKey: nil))
        let decision = TapPolicy.decide(down, role: .keys, recording: false, swallowedKey: 96, idleKeysReported: false)
        #expect(TapPolicy.countsAsUserInput(down, decision: decision, swallowedKey: 96))
    }

    @Test func ourOwnEventsTheHotkeyAndKeyUpsDoNotCountAsUserInput() {
        let stamped = sample(.keyDown, 9, userData: SyntheticEvents.stamp)
        #expect(!TapPolicy.countsAsUserInput(stamped, decision: .passThrough, swallowedKey: nil))
        #expect(!TapPolicy.countsAsUserInput(sample(.keyDown, 96), decision: TapDecision(swallow: true, deliver: true), swallowedKey: 96))
        #expect(!TapPolicy.countsAsUserInput(sample(.keyDown, 179), decision: .passThrough, swallowedKey: nil))
        #expect(!TapPolicy.countsAsUserInput(sample(.keyUp, 36), decision: .passThrough, swallowedKey: nil))
        #expect(!TapPolicy.countsAsUserInput(sample(.flagsChanged, 55), decision: .passThrough, swallowedKey: nil))
        // Escape swallowed to cancel a recording never reaches the app.
        #expect(!TapPolicy.countsAsUserInput(sample(.keyDown, 53), decision: TapDecision(swallow: true, deliver: true), swallowedKey: nil))
    }

    @Test func anEmulatedFnComboCountsBecauseItsReplacementReachesTheApp() {
        let decision = TapPolicy.decide(sample(.keyDown, 126), role: .keys, recording: false, swallowedKey: 96, hotkeyHeld: true)
        #expect(decision.swallow && decision.replacement != nil)
        #expect(TapPolicy.countsAsUserInput(sample(.keyDown, 126), decision: decision, swallowedKey: 96))
    }

    @Test func mouseDownsAreRecognisedAndMovesAreNot() {
        for type in [CGEventType.leftMouseDown, .rightMouseDown, .otherMouseDown] { #expect(TapPolicy.isPointerDown(type)) }
        for type in [CGEventType.leftMouseUp, .mouseMoved, .scrollWheel, .keyDown] { #expect(!TapPolicy.isPointerDown(type)) }
    }

    @Test func theInputGenerationIsNilUntilTheTapsVouchForIt() {
        let shared = TapShared()
        #expect(shared.userInputGeneration == nil)
        shared.inputTracked.store(true, ordering: .relaxed)
        shared.userInput.wrappingAdd(1, ordering: .relaxed)
        #expect(shared.userInputGeneration == 1)
    }

    @Test func flagsTapNeverSwallows() {
        let decision = TapPolicy.decide(sample(.flagsChanged, 63), role: .flags, recording: true, swallowedKey: nil)
        #expect(decision == .observe)
    }

    @Test func keyTapSwallowsEscapeWhileRecording() {
        for kind in [TapSample.Kind.keyDown, .keyUp] {
            let decision = TapPolicy.decide(sample(kind, 53), role: .keys, recording: true, swallowedKey: nil)
            #expect(decision == TapDecision(swallow: true, deliver: true))
        }
    }

    @Test func escapePassesWhenNotRecording() {
        #expect(TapPolicy.decide(sample(.keyDown, 53), role: .keys, recording: false, swallowedKey: nil) == .observe)
    }

    @Test func everyOtherKeyPassesAndIsReported() {
        #expect(TapPolicy.decide(sample(.keyDown, 0), role: .keys, recording: true, swallowedKey: nil) == .observe)
    }

    @Test func syntheticFnReleaseKeyDownPassesUnreported() {
        #expect(TapPolicy.decide(sample(.keyDown, 179), role: .keys, recording: true, swallowedKey: nil) == .passThrough)
    }

    @Test func ownStampedEventsPassUntouchedEvenEscape() {
        let stamped = sample(.keyDown, 53, userData: SyntheticEvents.stamp)
        #expect(TapPolicy.decide(stamped, role: .keys, recording: true, swallowedKey: nil) == .passThrough)
        #expect(TapPolicy.decide(stamped, role: .keys, recording: true, swallowedKey: 53) == .passThrough)
        let stampedFlags = sample(.flagsChanged, 55, userData: SyntheticEvents.stamp)
        #expect(TapPolicy.decide(stampedFlags, role: .flags, recording: false, swallowedKey: nil) == .passThrough)
    }

    @Test func remapDestinationKeyIsSwallowedAndReported() {
        let decision = TapPolicy.decide(sample(.keyDown, 80), role: .keys, recording: false, swallowedKey: 80)
        #expect(decision == TapDecision(swallow: true, deliver: true))
    }

    @Test func samplesFromRawCGEventsCarryTheFields() throws {
        let event = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 12, keyDown: true))
        event.setIntegerValueField(.eventSourceUserData, value: SyntheticEvents.stamp)
        event.timestamp = 777
        let sample = try #require(TapSample(type: .keyDown, event: event))
        #expect(sample.kind == .keyDown)
        #expect(sample.keyCode == 12)
        #expect(sample.userData == SyntheticEvents.stamp)
        #expect(sample.timestamp == 777)
        #expect(!sample.isAutorepeat)
        #expect(TapSample(type: .leftMouseDown, event: event) == nil)
    }

    // MARK: Fn combo emulation and Fn+Space

    private func decide(
        _ kind: TapSample.Kind, _ keyCode: UInt16, held: Bool = true, recording: Bool = false, remap: Bool = true,
        pending: TapPending? = nil, autorepeat: Bool = false, userData: Int64 = 0
    ) -> TapDecision {
        let sample = TapSample(kind: kind, keyCode: keyCode, flags: 0, timestamp: 0, userData: userData, isAutorepeat: autorepeat)
        return TapPolicy.decide(
            sample, role: .keys, recording: recording, swallowedKey: remap ? 80 : nil, hotkeyHeld: held, pending: pending
        )
    }

    @Test func emulationTableMapsTheSixFnCombos() {
        let expected: [(UInt16, UInt16, Bool)] = [
            (126, 116, false), (125, 121, false), (123, 115, false), (124, 119, false), (51, 117, false), (36, 76, true),
        ]
        for (from, to, keypad) in expected {
            let combo = FnCombos.replacement(forKeyCode: from, fnHeld: true)
            #expect(combo == FnCombo(keyCode: to, keypad: keypad), "key \(from)")
            #expect(FnCombos.replacement(forKeyCode: from, fnHeld: false) == nil)
        }
        #expect(FnCombos.replacement(forKeyCode: 0, fnHeld: true) == nil)
        #expect(FnCombos.replacement(forKeyCode: 49, fnHeld: true) == nil)
    }

    @Test func replacementKeepsModifiersAndFixesTheKeypadFlag() {
        let shift = CGEventFlags.maskShift.rawValue
        let pad = CGEventFlags.maskNumericPad.rawValue
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let arrow = FnCombos.flags(for: FnCombo(keyCode: 121), original: shift | pad)
        #expect(arrow & shift != 0 && arrow & pad == 0 && arrow & fn != 0)
        let enter = FnCombos.flags(for: FnCombo(keyCode: 76, keypad: true), original: shift)
        #expect(enter & shift != 0 && enter & pad != 0 && enter & fn != 0)
    }

    @Test func fnArrowIsSwallowedReplacedAndCountsAsAChord() {
        for kind in [TapSample.Kind.keyDown] {
            let decision = decide(kind, 125)
            #expect(decision == TapDecision(swallow: true, deliver: true, replacement: FnCombo(keyCode: 121)))
        }
    }

    @Test func autorepeatIsEmulatedButNotReportedAgain() {
        let decision = decide(.keyDown, 125, autorepeat: true)
        #expect(decision == TapDecision(swallow: true, deliver: false, replacement: FnCombo(keyCode: 121)))
    }

    @Test func keyUpAndRepeatsFollowTheDownEvenAfterFnCameUp() {
        let pending = TapPending.emulated(FnCombo(keyCode: 121))
        let up = decide(.keyUp, 125, held: false, pending: pending)
        #expect(up == TapDecision(swallow: true, deliver: false, replacement: FnCombo(keyCode: 121)))
        let repeatDown = decide(.keyDown, 125, held: false, pending: pending, autorepeat: true)
        #expect(repeatDown.replacement == FnCombo(keyCode: 121) && repeatDown.swallow)
        // A fresh press with Fn up is a plain arrow again, whatever stale state is pending.
        #expect(decide(.keyDown, 125, held: false, pending: pending) == .observe)
    }

    @Test func arrowsPassWhenFnIsNotHeldOrWhenNotInRemapMode() {
        #expect(decide(.keyDown, 125, held: false) == .observe)
        #expect(decide(.keyDown, 125, remap: false) == .observe)
    }

    @Test func otherKeysWhileHeldPassUntouchedButCountAsAChord() {
        #expect(decide(.keyDown, 0) == .observe)
        #expect(decide(.keyUp, 0) == .observe)
    }

    @Test func spaceWhileHeldAndRecordingIsSwallowedBothWays() {
        #expect(decide(.keyDown, 49, recording: true) == TapDecision(swallow: true, deliver: true))
        let held = TapPending.swallowed
        #expect(decide(.keyUp, 49, held: false, recording: true, pending: held) == TapDecision(swallow: true, deliver: false))
        #expect(decide(.keyDown, 49, held: true, recording: true, pending: held, autorepeat: true) == TapDecision(swallow: true, deliver: false))
        // The same in Fn flag mode, where there is no emulation.
        #expect(decide(.keyDown, 49, recording: true, remap: false) == TapDecision(swallow: true, deliver: true))
    }

    @Test func spaceIsLeftAloneWhenNothingIsRecordingOrFnIsUp() {
        #expect(decide(.keyDown, 49, recording: false) == .observe)
        #expect(decide(.keyDown, 49, held: false, recording: true) == .observe)
    }

    @Test func pendingChangesFollowTheDecision() {
        func sample(_ kind: TapSample.Kind, _ code: UInt16, repeating: Bool = false) -> TapSample {
            TapSample(kind: kind, keyCode: code, flags: 0, timestamp: 0, isAutorepeat: repeating)
        }
        let emulate = TapDecision(swallow: true, deliver: true, replacement: FnCombo(keyCode: 121))
        #expect(TapPolicy.pendingChange(for: sample(.keyDown, 125), decision: emulate) == .set(.emulated(FnCombo(keyCode: 121))))
        #expect(TapPolicy.pendingChange(for: sample(.keyDown, 125, repeating: true), decision: emulate) == .none)
        #expect(TapPolicy.pendingChange(for: sample(.keyUp, 125), decision: emulate) == .clear)
        #expect(TapPolicy.pendingChange(for: sample(.keyDown, 49), decision: TapDecision(swallow: true, deliver: true)) == .set(.swallowed))
        #expect(TapPolicy.pendingChange(for: sample(.keyDown, 53), decision: TapDecision(swallow: true, deliver: true)) == .none)
        #expect(TapPolicy.pendingChange(for: sample(.keyDown, 0), decision: .observe) == .none)
    }

    @Test func remapKeySwallowedBothWaysAndItsOwnStampPasses() {
        for kind in [TapSample.Kind.keyDown, .keyUp] {
            #expect(decide(kind, 80) == TapDecision(swallow: true, deliver: true))
        }
        #expect(decide(.keyDown, 125, userData: SyntheticEvents.stamp) == .passThrough)
        #expect(decide(.keyUp, 125, pending: .emulated(FnCombo(keyCode: 121)), userData: SyntheticEvents.stamp) == .passThrough)
        #expect(decide(.keyDown, 49, recording: true, userData: SyntheticEvents.stamp) == .passThrough)
    }

    @Test func idleKeysAreNotReportedUnlessAskedFor() {
        let sample = TapSample(kind: .keyDown, keyCode: 0, flags: 0, timestamp: 0)
        let idle = TapPolicy.decide(sample, role: .keys, recording: false, swallowedKey: 80, idleKeysReported: false)
        #expect(idle == .passThrough)
        let held = TapPolicy.decide(sample, role: .keys, recording: false, swallowedKey: 80, hotkeyHeld: true, idleKeysReported: false)
        #expect(held == .observe)
        let recording = TapPolicy.decide(sample, role: .keys, recording: true, swallowedKey: 80, idleKeysReported: false)
        #expect(recording == .observe)
    }

    @Test func holdIsTrackedFromTheRemapKeyOrTheFnFlag() {
        func s(_ kind: TapSample.Kind, _ code: UInt16, flags: UInt64 = 0, userData: Int64 = 0) -> TapSample {
            TapSample(kind: kind, keyCode: code, flags: flags, timestamp: 0, userData: userData)
        }
        #expect(TapPolicy.holdChange(s(.keyDown, 80), swallowedKey: 80, tracksFnFlag: false) == true)
        #expect(TapPolicy.holdChange(s(.keyUp, 80), swallowedKey: 80, tracksFnFlag: false) == false)
        #expect(TapPolicy.holdChange(s(.keyDown, 0), swallowedKey: 80, tracksFnFlag: false) == nil)
        #expect(TapPolicy.holdChange(s(.keyDown, 80, userData: SyntheticEvents.stamp), swallowedKey: 80, tracksFnFlag: false) == nil)
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        #expect(TapPolicy.holdChange(s(.flagsChanged, 63, flags: fn), swallowedKey: nil, tracksFnFlag: true) == true)
        #expect(TapPolicy.holdChange(s(.flagsChanged, 63, flags: 0), swallowedKey: nil, tracksFnFlag: true) == false)
        #expect(TapPolicy.holdChange(s(.flagsChanged, 63, flags: fn), swallowedKey: 80, tracksFnFlag: false) == nil)
    }
}
