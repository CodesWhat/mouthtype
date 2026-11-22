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

    /// Half a second at 48 kHz, half a second at 44.1 kHz, then half a second at 48 kHz again: a Bluetooth mic
    /// renegotiating its rate and coming back. Each segment has its own level.
    private static let take: [(level: Float, rate: Double)] = [(0.25, 48_000), (0.5, 44_100), (0.75, 48_000)]

    /// Feeds one segment of the take in 10 ms buffers.
    private func feedSegment(_ index: Int, _ feed: (AVAudioPCMBuffer) -> Void) throws {
        let (value, rate) = Self.take[index]
        let pcm = try level(value, sampleRate: rate, frames: AVAudioFrameCount(rate / 100))
        for _ in 0..<50 { feed(pcm) }
    }

    private func feedTakeAcrossFormatChanges(_ feed: (AVAudioPCMBuffer) -> Void) throws {
        for index in Self.take.indices { try feedSegment(index, feed) }
    }

    /// What one segment produces on its own: every buffer through a fresh cache, then drained. This is what the
    /// same segment has to produce inside a take that changes format around it.
    private func segmentAlone(_ index: Int) throws -> [Float] {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        var samples: [Float] = []
        try feedSegment(index) { pcm in
            #expect(cache.convert(pcm) { samples.append(contentsOf: $0) })
        }
        cache.drain { samples.append(contentsOf: $0) }
        return samples
    }

    /// Which segment (1, 2, 3) each sample belongs to, skipping the few samples of filter edge between levels.
    private func segments(_ samples: [Float]) -> [Int] {
        samples.compactMap { sample in
            [0.25, 0.5, 0.75].firstIndex { abs(sample - $0) < 0.05 }.map { $0 + 1 }
        }
    }

    private func expectWholeTakeInOrder(_ samples: [Float]) throws {
        let alone = try Self.take.indices.map { try segmentAlone($0) }
        let labels = segments(samples)
        #expect(zip(labels, labels.dropFirst()).allSatisfy { $0 <= $1 }, "a segment's audio came out after a later segment's")
        // Each segment comes out whole, exactly as it does with no format change around it. A converter that
        // was not flushed before the switch away from it holds back about six samples, so its segment is short.
        #expect(samples.count == alone.reduce(0) { $0 + $1.count })
        for (index, reference) in alone.enumerated() {
            let segment = index + 1
            let count = labels.count { $0 == segment }
            let expected = segments(reference).count { $0 == segment }
            #expect(expected > 7_900, "segment \(segment) alone has \(expected) samples")
            // One sample either way: a neighbouring segment's filter edge can pass through this level at a switch.
            #expect(abs(count - expected) <= 1, "segment \(segment) has \(count) samples, \(expected) on its own")
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
        try expectWholeTakeInOrder(samples)
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
        try expectWholeTakeInOrder(try buffer.finish())
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
