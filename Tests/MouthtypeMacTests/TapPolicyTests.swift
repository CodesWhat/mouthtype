import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct TapPolicyTests {
    private func sample(_ kind: TapSample.Kind, _ keyCode: UInt16, userData: Int64 = 0) -> TapSample {
        TapSample(kind: kind, keyCode: keyCode, flags: 0, timestamp: 0, userData: userData)
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
}
