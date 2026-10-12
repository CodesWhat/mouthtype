// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SilenceTrimmerTests {
    private func tone(_ seconds: Double, level: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { level * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func noise(_ seconds: Double, level: Float) -> [Float] {
        var generator = SystemRandomNumberGenerator()
        return (0..<Int(seconds * 16_000)).map { _ in Float.random(in: -level...level, using: &generator) }
    }

    @Test func cutsQuietEdgesAndKeepsMargins() throws {
        let audio = noise(1.0, level: 0.002) + tone(2.0, level: 0.3) + noise(2.0, level: 0.002)
        let trimmed = SilenceTrimmer.trim(audio)
        let expected = 2.0 + SilenceTrimmer.leadMargin + SilenceTrimmer.trailMargin
        #expect(abs(Double(trimmed.samples.count) / 16_000 - expected) < 0.02)
        let range = try #require(SilenceTrimmer.voicedRange(audio))
        #expect(abs(Double(range.lowerBound) / 16_000 - (1.0 - SilenceTrimmer.leadMargin)) < 0.02)
    }

    @Test func reportsMillisecondsTrimmedFromTheHead() {
        let audio = noise(1.0, level: 0.002) + tone(2.0, level: 0.3) + noise(2.0, level: 0.002)
        let trimmed = SilenceTrimmer.trim(audio)
        #expect(abs(trimmed.headTrimmedMs - 750) < 20)
        let tail = 2000 - 350.0
        #expect(abs(trimmed.tailTrimmedMs - tail) < 20)
    }

    @Test func keepsAudioWithNothingAboveTheFloor() {
        let silence = noise(2.0, level: 0.001)
        #expect(SilenceTrimmer.trim(silence).samples == silence)
        #expect(SilenceTrimmer.trim(silence).headTrimmedMs == 0)
        #expect(SilenceTrimmer.trim([]).samples == [])
    }

    @Test func leavesSpeechToTheEdgesAlone() {
        let speech = tone(1.0, level: 0.3)
        let trimmed = SilenceTrimmer.trim(speech)
        #expect(trimmed.samples.count == speech.count)
        #expect(trimmed.headTrimmedMs == 0)
    }

    @Test func keepsQuietWordsBetweenLoudOnes() throws {
        // A soft word in the middle is inside the kept range whatever its level.
        let audio = noise(0.5, level: 0.001) + tone(0.5, level: 0.3) + tone(0.5, level: 0.004) + tone(0.5, level: 0.3) + noise(0.5, level: 0.001)
        let range = try #require(SilenceTrimmer.voicedRange(audio))
        #expect(range.lowerBound <= 8_000)
        #expect(range.upperBound >= 32_000)
    }

    @Test func noiseLoudEnoughToHideSpeechLeavesTheCaptureWhole() {
        // Noise above 5% of the peak counts as voiced, so nothing is cut.
        let audio = noise(1.0, level: 0.05) + tone(1.0, level: 0.3) + noise(1.0, level: 0.05)
        #expect(SilenceTrimmer.trim(audio).samples.count == audio.count)
    }
}
