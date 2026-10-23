import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SilentTakeTests {
    private func features(peak: Double, voiced: Double) -> AudioFeatures {
        AudioFeatures(rmsDb: peak - 6, peakDb: peak, noiseFloorDb: peak - 20, voicedMs: voiced)
    }

    @Test func noEnergyAtAllIsNoSignal() {
        #expect(SilentTakeKind.classify(AudioFeatures.compute(samples: [Float](repeating: 0, count: 16_000))) == .noSignal)
        #expect(SilentTakeKind.classify(features(peak: -80, voiced: 0)) == .noSignal)
    }

    @Test func soundWithNoVoicedAudioIsNoSpeech() {
        #expect(SilentTakeKind.classify(features(peak: -50, voiced: 0)) == .noSpeech)
    }

    @Test func aBlipOfSpeechIsTooShortNotAMicProblem() {
        let kind = SilentTakeKind.classify(features(peak: -20, voiced: 120))
        #expect(kind == .tooShort)
        #expect(!kind.warrants)
    }

    @Test func realSpeechIsSpoke() {
        #expect(SilentTakeKind.classify(features(peak: -20, voiced: 800)) == .spoke)
    }

    @Test func onlyNoSignalAndNoSpeechWarrantACard() {
        #expect(SilentTakeKind.noSignal.warrants && SilentTakeKind.noSpeech.warrants)
        #expect(!SilentTakeKind.tooShort.warrants && !SilentTakeKind.spoke.warrants)
    }

    @Test func aShortHoldNeverWarns() {
        var warning = SilentTakeWarning()
        let quiet = features(peak: -90, voiced: 0)
        #expect(warning.check(quiet, holdMs: 999, now: Date(timeIntervalSince1970: 0)) == nil)
        // A refused short hold doesn't start the cooldown.
        #expect(warning.check(quiet, holdMs: 1_000, now: Date(timeIntervalSince1970: 1)) == .noSignal)
    }

    @Test func aWarningHoldsBackTheNextUntilTheCooldownPasses() {
        var warning = SilentTakeWarning()
        let quiet = features(peak: -90, voiced: 0)
        let start = Date(timeIntervalSince1970: 100)
        #expect(warning.check(quiet, holdMs: 2_000, now: start) == .noSignal)
        #expect(warning.check(quiet, holdMs: 2_000, now: start.addingTimeInterval(5)) == nil)
        #expect(warning.check(quiet, holdMs: 2_000, now: start.addingTimeInterval(SilentTakeWarning.cooldown - 0.1)) == nil)
        #expect(warning.check(quiet, holdMs: 2_000, now: start.addingTimeInterval(SilentTakeWarning.cooldown)) == .noSignal)
    }

    @Test func aTakeThatIsntWarnableDoesNotStartTheCooldown() {
        var warning = SilentTakeWarning()
        let now = Date(timeIntervalSince1970: 0)
        #expect(warning.check(features(peak: -20, voiced: 800), holdMs: 3_000, now: now) == nil)
        #expect(warning.check(features(peak: -90, voiced: 0), holdMs: 3_000, now: now) == .noSignal)
    }
}
