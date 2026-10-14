// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import Foundation
import Testing
@testable import MouthtypeMac

func makePCM(sampleRate: Double, channels: AVAudioChannelCount, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false
    ))
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let data = try #require(buffer.floatChannelData)
    for c in 0..<Int(channels) {
        for i in 0..<Int(frames) {
            data[c][i] = sinf(2 * .pi * 440 * Float(i) / Float(sampleRate)) * 0.5
        }
    }
    return buffer
}

@Suite struct CaptureBufferTests {
    private func append(_ samples: [Float], inputFrames: Int = 0, at now: UInt64 = 0, to buffer: CaptureBuffer) {
        samples.withUnsafeBufferPointer { buffer.append($0, inputFrames: inputFrames, at: now) }
    }

    @Test func zeroHzOrZeroChannelsThrowsInsteadOfReachingTheUnit() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (0, 0), (.nan, 1)] {
            #expect(throws: CaptureError.self) { try InputDevice.validate(sampleRate: rate, channels: channels) }
        }
        #expect(throws: Never.self) { try InputDevice.validate(sampleRate: 44_100, channels: 1) }
    }

    @Test func routeChangeDiscardsThePartialCapture() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        append([0.1, 0.2, 0.3], to: buffer)
        buffer.markRouteChanged()
        append([0.4], to: buffer)

        do {
            _ = try buffer.finish()
            Issue.record("expected routeChanged")
        } catch CaptureError.routeChanged {
        }
        // The next recording starts clean and succeeds.
        buffer.reset(startedAt: 0)
        append([0.5], to: buffer)
        #expect(try buffer.finish() == [0.5])
    }

    @Test func finishReturnsSamplesAndStats() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 1_000_000_000)
        append([0.1, 0.2], inputFrames: 6, at: 1_050_000_000, to: buffer)
        append([0.3], inputFrames: 3, at: 1_090_000_000, to: buffer)
        buffer.recordConversionFailure()

        let stats = buffer.currentStats
        #expect(stats.buffers == 2)
        #expect(stats.inputFrames == 9)
        #expect(stats.conversionFailures == 1)
        #expect(abs(try #require(stats.firstBufferDelay) - 0.05) < 1e-9)
        #expect(try buffer.finish() == [0.1, 0.2, 0.3])
        #expect(try buffer.finish() == [])
    }

    @Test func firstSampleAndFirstSoundAreMeasuredFromThePress() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 1_000_000_000)
        #expect(buffer.awaitingSound)
        // First buffer: captured 120 ms after the press, all zeros.
        buffer.noteInput(firstFrameAt: 1_120_000_000, firstSoundAt: nil)
        #expect(buffer.awaitingSound)
        // Second buffer: sound starts 150 ms after the press.
        buffer.noteInput(firstFrameAt: 1_130_000_000, firstSoundAt: 1_150_000_000)
        #expect(!buffer.awaitingSound)
        buffer.noteInput(firstFrameAt: 1_140_000_000, firstSoundAt: 1_140_000_000)

        let stats = buffer.currentStats
        #expect(abs(try #require(stats.firstSampleDelay) - 0.120) < 1e-9)
        #expect(abs(try #require(stats.firstSoundDelay) - 0.150) < 1e-9)

        buffer.reset(startedAt: 2_000_000_000)
        #expect(buffer.currentStats.firstSampleDelay == nil)
        #expect(buffer.awaitingSound)
    }

    @Test func aSampleCapturedBeforeThePressReadsNegative() throws {
        // Would mean the input ran before the press; it must not wrap around.
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 1_000_000_000)
        buffer.noteInput(firstFrameAt: 990_000_000, firstSoundAt: nil)
        #expect(abs(try #require(buffer.currentStats.firstSampleDelay) + 0.010) < 1e-9)
    }

    @Test func firstNonZeroFrame() throws {
        let silent = try makePCM(sampleRate: 48_000, channels: 2, frames: 480)
        let data = try #require(silent.floatChannelData)
        for c in 0..<2 { for i in 0..<480 { data[c][i] = 0 } }
        #expect(AudioCapture.firstNonZeroFrame(silent) == nil)
        data[1][300] = 0.01
        #expect(AudioCapture.firstNonZeroFrame(silent) == 300)
        data[0][120] = -0.02
        #expect(AudioCapture.firstNonZeroFrame(silent) == 120)
    }

    @Test func inputHandlerNotesTimingAndConverts() throws {
        let buffer = CaptureBuffer()
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        buffer.reset(startedAt: 1_000_000_000)
        let handle = AudioCapture.inputHandler(buffer: buffer, converters: cache, onLevel: nil)
        let pcm = try makePCM(sampleRate: 48_000, channels: 1, frames: 4_800)
        // The sine starts at zero, so sound starts one frame in: ~20.8 µs.
        handle(pcm, 1_100_000_000, 1_200_000_000)
        let stats = buffer.currentStats
        #expect(abs(try #require(stats.firstSampleDelay) - 0.100) < 1e-9)
        #expect(abs(try #require(stats.firstSoundDelay) - (0.100 + 1.0 / 48_000)) < 1e-6)
        #expect(abs(try #require(stats.firstBufferDelay) - 0.200) < 1e-9)
        #expect(stats.inputFrames == 4_800)
    }

    @Test func inputHandlerReportsLevelPerBuffer() throws {
        let buffer = CaptureBuffer()
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        buffer.reset(startedAt: 0)
        let meter = LevelMeter()
        let handle = AudioCapture.inputHandler(buffer: buffer, converters: cache, onLevel: { meter.update(samples: $0) })
        handle(try makePCM(sampleRate: 48_000, channels: 1, frames: 4_800), 0, 0)
        // A 0.5 sine is about -9 dBFS RMS.
        #expect(meter.reading.db > -11 && meter.reading.db < -7)
    }

    @Test func buffersOutsideARecordingAreCountedAndDropped() throws {
        let buffer = CaptureBuffer()
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        let handle = AudioCapture.inputHandler(buffer: buffer, converters: cache, onLevel: nil)
        let pcm = try makePCM(sampleRate: 48_000, channels: 1, frames: 480)

        handle(pcm, 0, 0)
        #expect(buffer.buffersWhileClosed == 1)
        #expect(buffer.currentStats.buffers == 0)

        buffer.reset(startedAt: 0)
        handle(pcm, 0, 0)
        #expect(buffer.currentStats.buffers == 1)
        _ = try buffer.finish()
        handle(pcm, 0, 0)
        #expect(buffer.buffersWhileClosed == 2)
    }

    @Test func inputFailuresAreCountedPerRecording() {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        buffer.recordInputFailure()
        buffer.recordInputFailure()
        #expect(buffer.currentStats.inputFailures == 2)
        buffer.reset(startedAt: 0)
        #expect(buffer.currentStats.inputFailures == 0)
    }

    @Test func resetClearsARouteChangeFromTheLastRecording() throws {
        let buffer = CaptureBuffer()
        buffer.markRouteChanged()
        buffer.reset(startedAt: 0)
        #expect(try buffer.finish() == [])
        #expect(buffer.currentStats.firstBufferDelay == nil)
    }

    @Test func hostClockConvertsAndSubtractsSigned() {
        #expect(abs(HostClock.seconds(from: 2_000_000_000, to: 1_500_000_000) + 0.5) < 1e-12)
        let a = HostClock.now()
        let b = HostClock.nanoseconds(fromHostTime: mach_absolute_time())
        #expect(b >= a)
        #expect(b - a < 1_000_000_000)
    }
}

@Suite struct CaptureBufferInterruptionTests {
    private func append(_ samples: [Float], to buffer: CaptureBuffer) {
        samples.withUnsafeBufferPointer { buffer.append($0, inputFrames: 0, at: 0) }
    }

    @Test func aSalvagingFinishKeepsWhatWasCapturedAfterARouteChange() throws {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        append([0.1, 0.2, 0.3], to: buffer)
        #expect(buffer.markRouteChanged())
        let (samples, changed) = buffer.finishSalvaging()
        #expect(samples == [0.1, 0.2, 0.3] && changed)
        buffer.reset(startedAt: 0)
        append([0.5], to: buffer)
        buffer.markRouteChanged()
        #expect(throws: CaptureError.self) { try buffer.finish() }
    }

    @Test func aRouteChangeIsAnnouncedOnlyTheFirstTimePerRecording() {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        #expect(buffer.markRouteChanged())
        #expect(!buffer.markRouteChanged())
        buffer.reset(startedAt: 0)
        #expect(buffer.markRouteChanged())
    }

    @Test func inputFailuresAreCounted() {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        #expect(buffer.recordInputFailure() == 1 && buffer.recordInputFailure() == 2)
    }

    @Test func theTailFromAnOffsetIsWhatHasntBeenSavedYet() {
        let buffer = CaptureBuffer()
        buffer.reset(startedAt: 0)
        #expect(buffer.samples(from: 0).isEmpty)
        append([1, 2, 3, 4], to: buffer)
        #expect(buffer.samples(from: 0) == [1, 2, 3, 4] && buffer.samples(from: 3) == [4] && buffer.samples(from: 4).isEmpty)
        append([5], to: buffer)
        #expect(buffer.samples(from: 4) == [5])
    }

    /// Core Audio calls the handler on its own thread; the hop must reach the main actor without the runtime's
    /// isolation check firing.
    @Test @MainActor func theHandlerRunsOnTheMainActorWhenCalledFromAnotherThread() async {
        var ran = 0
        let hop = CaptureInterruption.hop { MainActor.assertIsolated(); ran += 1 }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                hop()
                continuation.resume()
            }
        }
        for _ in 0..<50 where ran == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(ran == 1)
    }
}
