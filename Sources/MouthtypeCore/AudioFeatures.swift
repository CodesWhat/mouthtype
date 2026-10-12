import Foundation

/// Level features of a 16 kHz capture, kept so energy and mic stats survive without the audio.
/// Method: 10 ms frame RMS in dBFS; noise floor is the 10th percentile of frame levels; a frame is voiced
/// when it is above max(-45 dBFS, min(floor + 12 dB, loudest frame - 20 dB)), and each voiced frame holds the state
/// for 3 more frames. The loudest-frame term keeps a steady loud signal with no quiet frames from reading as unvoiced.
public struct AudioFeatures: Equatable, Sendable {
    public var rmsDb: Double
    public var peakDb: Double
    public var noiseFloorDb: Double
    public var voicedMs: Double

    public static let silenceDb = -120.0
    static let frameLength = 160
    static let marginDb = 12.0
    static let peakMarginDb = 20.0
    static let absoluteThresholdDb = -45.0
    static let hangoverFrames = 3

    public static func compute(samples: [Float], sampleRate: Int = 16_000) -> AudioFeatures {
        let silent = AudioFeatures(rmsDb: silenceDb, peakDb: silenceDb, noiseFloorDb: silenceDb, voicedMs: 0)
        guard !samples.isEmpty else { return silent }

        var totalSquares = 0.0
        var peak: Float = 0
        for s in samples {
            totalSquares += Double(s) * Double(s)
            peak = max(peak, abs(s))
        }
        let rms = (totalSquares / Double(samples.count)).squareRoot()

        let frameLength = max(1, sampleRate / 100)
        let frameCount = samples.count / frameLength
        guard frameCount > 0 else {
            return AudioFeatures(rmsDb: db(rms), peakDb: db(Double(peak)), noiseFloorDb: db(rms), voicedMs: 0)
        }
        var frameDb = [Double](repeating: 0, count: frameCount)
        for f in 0..<frameCount {
            var sum = 0.0
            for s in samples[(f * frameLength)..<((f + 1) * frameLength)] { sum += Double(s) * Double(s) }
            frameDb[f] = db((sum / Double(frameLength)).squareRoot())
        }
        let sorted = frameDb.sorted()
        let floorDb = sorted[min(frameCount - 1, frameCount / 10)]
        let threshold = max(absoluteThresholdDb, min(floorDb + marginDb, sorted[frameCount - 1] - peakMarginDb))

        var voiced = 0
        var hold = 0
        for level in frameDb {
            if level > threshold {
                voiced += 1
                hold = hangoverFrames
            } else if hold > 0 {
                voiced += 1
                hold -= 1
            }
        }
        return AudioFeatures(
            rmsDb: db(rms),
            peakDb: db(Double(peak)),
            noiseFloorDb: floorDb,
            voicedMs: Double(voiced * frameLength) * 1000 / Double(sampleRate)
        )
    }

    private static func db(_ amplitude: Double) -> Double {
        max(silenceDb, 20 * log10(max(amplitude, 1e-9)))
    }
}
