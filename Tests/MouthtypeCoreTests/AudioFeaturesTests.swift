import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioFeaturesTests {
    private func tone(_ seconds: Double, amplitude: Float) -> [Float] {
        (0..<Int(seconds * 16_000)).map { amplitude * sin(Float($0) * 2 * .pi * 220 / 16_000) }
    }

    private func silence(_ seconds: Double) -> [Float] {
        [Float](repeating: 0, count: Int(seconds * 16_000))
    }

    @Test func toneAndSilenceMeasure() {
        let audio = silence(1.0) + tone(1.0, amplitude: 0.5) + silence(1.0)
        let f = AudioFeatures.compute(samples: audio)
        #expect(abs(f.peakDb - 20 * log10(0.5)) < 0.1)
        // RMS of the whole clip: a 0.5 sine for a third of it.
        let expectedRms = 20 * log10(0.5 / 2.0.squareRoot() * (1.0 / 3.0).squareRoot())
        #expect(abs(f.rmsDb - expectedRms) < 0.2)
        #expect(f.noiseFloorDb < -100)
        // 1000 ms of tone plus the 30 ms hangover.
        #expect(abs(f.voicedMs - 1030) < 20)
    }

    @Test func steadyToneIsAllVoiced() {
        let f = AudioFeatures.compute(samples: tone(2.0, amplitude: 0.3))
        #expect(abs(f.voicedMs - 2000) < 20)
        #expect(abs(f.rmsDb - 20 * log10(0.3 / 2.0.squareRoot())) < 0.1)
    }

    @Test func silenceIsNeverVoiced() {
        let f = AudioFeatures.compute(samples: silence(2.0))
        #expect(f.voicedMs == 0)
        #expect(f.rmsDb == AudioFeatures.silenceDb)
        #expect(f.peakDb == AudioFeatures.silenceDb)
    }

    @Test func quietBackgroundNoiseStaysBelowTheThreshold() {
        var generator = SystemRandomNumberGenerator()
        let hiss = (0..<32_000).map { _ in Float.random(in: -0.002...0.002, using: &generator) }
        let f = AudioFeatures.compute(samples: hiss + tone(0.5, amplitude: 0.3) + hiss)
        #expect(abs(f.voicedMs - 530) < 30)
        #expect(f.noiseFloorDb < -50)
    }

    @Test func emptyInput() {
        let f = AudioFeatures.compute(samples: [])
        #expect(f.voicedMs == 0)
        #expect(f.noiseFloorDb == AudioFeatures.silenceDb)
    }
}
