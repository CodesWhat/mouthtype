// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// Cuts leading and trailing silence from a 16 kHz capture with a simple
/// energy threshold. Pure.
///
/// It errs toward keeping audio: a margin stays on each side, and a capture
/// whose loudest frame never clears the threshold comes back unchanged.
public enum SilenceTrimmer {
    public struct Result: Equatable, Sendable {
        public var samples: [Float]
        /// Milliseconds cut from the head. Word timings from the engine are relative to the trimmed audio; add this back.
        public var headTrimmedMs: Double
        public var tailTrimmedMs: Double
    }

    public static let sampleRate = 16_000
    /// 10 ms frames.
    public static let frameLength = 160
    /// Frames quieter than this RMS are silence whatever the rest of the capture.
    public static let minimumLevel: Float = 0.003
    /// Frames quieter than this fraction of the loudest frame's RMS (-26 dB) are silence.
    public static let relativeLevel: Float = 0.05
    /// Audio kept before the first voiced frame, for soft onsets.
    public static let leadMargin = 0.25
    /// Audio kept after the last voiced frame, for trailing consonants.
    public static let trailMargin = 0.35

    public static func trim(_ audio: [Float]) -> Result {
        guard let range = voicedRange(audio), range.count != audio.count else {
            return Result(samples: audio, headTrimmedMs: 0, tailTrimmedMs: 0)
        }
        return Result(
            samples: Array(audio[range]),
            headTrimmedMs: Double(range.lowerBound) * 1000 / Double(sampleRate),
            tailTrimmedMs: Double(audio.count - range.upperBound) * 1000 / Double(sampleRate)
        )
    }

    /// The sample range to keep, or nil if nothing clears the threshold.
    public static func voicedRange(_ audio: [Float]) -> Range<Int>? {
        let frames = audio.count / frameLength
        guard frames > 0 else { return nil }
        var levels = [Float](repeating: 0, count: frames)
        audio.withUnsafeBufferPointer { samples in
            for f in 0..<frames {
                var sum: Float = 0
                for s in samples[(f * frameLength)..<((f + 1) * frameLength)] { sum += s * s }
                levels[f] = (sum / Float(frameLength)).squareRoot()
            }
        }
        let peak = levels.max() ?? 0
        let threshold = max(minimumLevel, peak * relativeLevel)
        guard peak >= threshold,
              let first = levels.firstIndex(where: { $0 >= threshold }),
              let last = levels.lastIndex(where: { $0 >= threshold })
        else { return nil }
        let start = max(0, first * frameLength - Int(leadMargin * Double(sampleRate)))
        let end = min(audio.count, (last + 1) * frameLength + Int(trailMargin * Double(sampleRate)))
        return start..<end
    }
}
