// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct ConverterCacheTests {
    @Test func converterIsBuiltOncePerInputFormat() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let stereo48 = try makePCM(sampleRate: 48_000, channels: 2, frames: 4_800)
        let mono44 = try makePCM(sampleRate: 44_100, channels: 1, frames: 4_410)

        #expect(cache.count == 0)
        #expect(cache.convert(stereo48) { _ in })
        #expect(cache.convert(stereo48) { _ in })
        #expect(cache.count == 1)
        #expect(cache.convert(mono44) { _ in })
        #expect(cache.count == 2)
        #expect(cache.convert(stereo48) { _ in })
        #expect(cache.count == 2)
    }

    @Test func convertsToSixteenKilohertzWithoutLosingTheTail() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let input = try makePCM(sampleRate: 48_000, channels: 2, frames: 4_800)
        var converted = 0
        // One second in 100 ms buffers. The resampler emits in blocks and holds the remainder until drained.
        for _ in 0..<10 {
            #expect(cache.convert(input) { converted += $0.count })
        }
        #expect(converted < 16_000)
        var drained = 0
        cache.drain { drained += $0.count }
        #expect(drained > 0)
        #expect(abs(Double(converted + drained) - 16_000) <= 32)
    }

    /// A buffer holding one constant level, so every output sample says which segment of a take it came from.
    private func level(_ value: Float, sampleRate: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let pcm = try makePCM(sampleRate: sampleRate, channels: 1, frames: frames)
        let data = try #require(pcm.floatChannelData)
        for i in 0..<Int(frames) { data[0][i] = value }
        return pcm
    }

    /// Half a second at 48 kHz, half a second at 44.1 kHz, then half a second at 48 kHz again, in 10 ms buffers:
    /// a Bluetooth mic renegotiating its rate and coming back. Each segment has its own level.
    private func feedTakeAcrossFormatChanges(_ feed: (AVAudioPCMBuffer) -> Void) throws {
        for (value, rate) in [(Float(0.25), 48_000.0), (0.5, 44_100), (0.75, 48_000)] {
            let pcm = try level(value, sampleRate: rate, frames: AVAudioFrameCount(rate / 100))
            for _ in 0..<50 { feed(pcm) }
        }
    }

    /// Which segment (1, 2, 3) each sample belongs to, skipping the few samples of filter edge between levels.
    private func segments(_ samples: [Float]) -> [Int] {
        samples.compactMap { sample in
            [0.25, 0.5, 0.75].firstIndex { abs(sample - $0) < 0.05 }.map { $0 + 1 }
        }
    }

    private func expectWholeTakeInOrder(_ samples: [Float]) {
        // 1.5 s at 16 kHz. Each converter holds back about six samples until it is flushed, so a take that
        // skipped a flush comes up short by more than this allows.
        #expect(abs(samples.count - 24_000) <= 4)
        let labels = segments(samples)
        #expect(zip(labels, labels.dropFirst()).allSatisfy { $0 <= $1 }, "a segment's audio came out after a later segment's")
        // Each segment is 8,000 samples, less a sample or two of filter edge. One whose converter was not
        // flushed is missing its end.
        for segment in 1...3 {
            let count = labels.count { $0 == segment }
            #expect(abs(count - 8_000) <= 4, "segment \(segment) has \(count) samples")
        }
        // The end of the first segment is still there right before the second starts.
        let firstOfSecond = samples.firstIndex { abs($0 - 0.5) < 0.05 } ?? 0
        let before = samples[max(0, firstOfSecond - 480)..<firstOfSecond]
        #expect(before.count { abs($0 - 0.25) < 0.05 } >= 476)
    }

    @Test func aFormatChangeFlushesThePreviousConverterInOrder() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        var samples: [Float] = []
        try feedTakeAcrossFormatChanges { pcm in
            #expect(cache.convert(pcm) { samples.append(contentsOf: $0) })
        }
        cache.drain { samples.append(contentsOf: $0) }
        #expect(cache.count == 2)
        expectWholeTakeInOrder(samples)
    }

    @Test func aFormatChangeTailLandsInTheCaptureBufferInOrder() throws {
        let buffer = CaptureBuffer()
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        buffer.reset(startedAt: 0)
        let handle = AudioCapture.inputHandler(buffer: buffer, converters: cache, onLevel: nil)
        try feedTakeAcrossFormatChanges { handle($0, 0, 0) }
        cache.drain { buffer.appendTail($0) }

        // The flushed tails are not input buffers and must not be counted as any.
        let stats = buffer.currentStats
        #expect(stats.buffers == 150)
        #expect(stats.inputFrames == 50 * (480 + 441 + 480))
        #expect(stats.conversionFailures == 0)
        expectWholeTakeInOrder(try buffer.finish())
    }

    @Test func aReturnToAnEarlierFormatStartsFromACleanConverter() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let first = try level(0.25, sampleRate: 48_000, frames: 4_800)
        let other = try level(0.5, sampleRate: 44_100, frames: 4_410)
        let back = try level(0.75, sampleRate: 48_000, frames: 4_800)
        #expect(cache.convert(first) { _ in })
        #expect(cache.convert(other) { _ in })
        var samples: [Float] = []
        #expect(cache.convert(back, tail: { _ in }) { samples.append(contentsOf: $0) })
        cache.drain { samples.append(contentsOf: $0) }
        // Only the third buffer's audio: nothing left over from the first use of this converter.
        #expect(abs(samples.count - 1_600) <= 32)
        #expect(!segments(samples).contains(1))
    }
}
