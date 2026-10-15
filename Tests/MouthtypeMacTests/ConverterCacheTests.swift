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
}
