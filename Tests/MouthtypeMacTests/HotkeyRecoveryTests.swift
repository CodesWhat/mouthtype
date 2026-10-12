// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct HotkeyRecoveryTests {
    private let t0 = Date(timeIntervalSinceReferenceDate: 0)

    @Test func backoffDoublesFromOneSecondToThirty() {
        let delays = (0...8).map { TapRecovery.delay(afterFailures: $0) }
        #expect(delays == [0, 1, 2, 4, 8, 16, 30, 30, 30])
        #expect(TapRecovery.delay(afterFailures: 10_000) == 30)
    }

    @Test func firstDisableReenablesAtOnce() {
        var recovery = TapRecovery()
        #expect(recovery.disabled(at: t0) == 0)
        #expect(recovery.failures == 0)
    }

    @Test func failedEnableBacksOff() {
        var recovery = TapRecovery()
        #expect(recovery.disabled(at: t0) == 0)
        #expect(recovery.enableFailed() == 1)
        #expect(recovery.enableFailed() == 2)
        #expect(recovery.enableFailed() == 4)
    }

    /// Secure Input can undo each re-enable at once. That must back off rather than loop.
    @Test func reenableUndoneQuicklyCountsAsFailure() {
        var recovery = TapRecovery()
        #expect(recovery.disabled(at: t0) == 0)
        recovery.enabled(at: t0)
        #expect(recovery.disabled(at: t0 + 0.1) == 1)
        recovery.enabled(at: t0 + 1.1)
        #expect(recovery.disabled(at: t0 + 1.2) == 2)
        recovery.enabled(at: t0 + 3.2)
        #expect(recovery.disabled(at: t0 + 3.3) == 4)
    }

    @Test func stableTapStartsOver() {
        var recovery = TapRecovery()
        _ = recovery.disabled(at: t0)
        _ = recovery.enableFailed()
        _ = recovery.enableFailed()
        recovery.enabled(at: t0 + 10)
        let later = t0 + 10 + TapRecovery.stableInterval
        #expect(recovery.disabled(at: later) == 0)
        #expect(recovery.failures == 0)
    }

    @Test func resyncEmitsOnlyAMissedRelease() {
        let fn = CGEventFlags.maskSecondaryFn.rawValue
        let missed = HotkeyService.resyncSample(source: .fnFlag, hotkeyHeld: true, currentFlags: 0, destinationKeyDown: false, hostTime: 5)
        #expect(missed == TapSample(kind: .flagsChanged, keyCode: 63, flags: 0, timestamp: 5))
        #expect(HotkeyService.resyncSample(source: .fnFlag, hotkeyHeld: true, currentFlags: fn, destinationKeyDown: false, hostTime: 5) == nil)
        #expect(HotkeyService.resyncSample(source: .fnFlag, hotkeyHeld: false, currentFlags: 0, destinationKeyDown: false, hostTime: 5) == nil)
        #expect(HotkeyService.resyncSample(source: .fnFlag, hotkeyHeld: false, currentFlags: fn, destinationKeyDown: false, hostTime: 5) == nil)
    }

    @Test func resyncForRemapReadsTheDestinationKey() {
        let source = HotkeySource.remapped(keyCode: 80)
        #expect(HotkeyService.resyncSample(source: source, hotkeyHeld: true, currentFlags: 0, destinationKeyDown: false, hostTime: 9)
            == TapSample(kind: .keyUp, keyCode: 80, flags: 0, timestamp: 9))
        #expect(HotkeyService.resyncSample(source: source, hotkeyHeld: true, currentFlags: 0, destinationKeyDown: true, hostTime: 9) == nil)
    }

    @Test func aMissedReleaseEndsTheRecordingThroughTheMapper() {
        var mapper = HotkeyInputMapper()
        _ = mapper.map(TapSample(kind: .flagsChanged, keyCode: 63, flags: CGEventFlags.maskSecondaryFn.rawValue, timestamp: 0), otherKeysHeld: { false })
        let resync = HotkeyService.resyncSample(source: .fnFlag, hotkeyHeld: mapper.hotkeyHeld, currentFlags: 0, destinationKeyDown: false, hostTime: 1)
        let mapped = resync.flatMap { mapper.map($0, otherKeysHeld: { false }) }
        #expect(mapped?.keyEvent.modifiers.isEmpty == true)
        #expect(!mapper.hotkeyHeld)
    }

    @Test func healthNamesTheCause() {
        func health(_ tap: Bool = true, recovering: Bool = false, secure: Bool = false, recording: Bool = false) -> HotkeyHealth {
            HotkeyHealth.resolve(tapPresent: tap, recovering: recovering, secureInput: secure, recording: recording)
        }
        #expect(health() == .listening)
        #expect(health(false) == .off)
        #expect(health(recovering: true) == .recovering)
        #expect(health(secure: true) == .secureInputOn)
        #expect(health(secure: true, recording: true) == .listening)
        #expect(health(recovering: true, secure: true) == .recovering)
        #expect(HotkeyHealth.listening.statusText == "Hotkey: listening")
        #expect(HotkeyHealth.off.statusText == "Hotkey: off")
        #expect(HotkeyHealth.recovering.statusText == "Hotkey: recovering")
        #expect(HotkeyHealth.secureInputOn.statusText == "Hotkey: secure input on")
    }
}
