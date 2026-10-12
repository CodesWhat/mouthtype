// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AVFoundation
import CoreAudio
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct HALInputTests {
    private let mic = InputDevice(sampleRate: 48_000, channels: 1, id: 42)

    @Test func clientFormatRefusesFormatsThatCannotBeRecorded() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (0, 0), (.nan, 1), (.infinity, 2), (-44_100, 1)] {
            #expect(HALInput.clientFormat(sampleRate: rate, channels: channels) == nil, "\(rate) Hz x \(channels)")
        }
    }

    @Test func clientFormatIsFloatAtTheDeviceRateWithAtMostTwoChannels() throws {
        let mono = try #require(HALInput.clientFormat(sampleRate: 44_100, channels: 1))
        #expect(mono.sampleRate == 44_100)
        #expect(mono.channelCount == 1)
        #expect(mono.commonFormat == .pcmFormatFloat32)
        #expect(!mono.isInterleaved)

        #expect(HALInput.clientFormat(sampleRate: 24_000, channels: 2)?.channelCount == 2)
        #expect(HALInput.clientFormat(sampleRate: 96_000, channels: 8)?.channelCount == 2)
    }

    @Test func everyClientFormatConvertsToSixteenKilohertzMono() throws {
        let cache = ConverterCache(targetFormat: AudioCapture.targetFormat)
        for (rate, channels) in [(8_000.0, UInt32(1)), (16_000, 1), (24_000, 1), (44_100, 1), (48_000, 2), (96_000, 4)] {
            let format = try #require(HALInput.clientFormat(sampleRate: rate, channels: channels))
            let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512))
            pcm.frameLength = 512
            #expect(cache.convert(pcm) { _ in }, "\(rate) Hz x \(channels)")
        }
    }

    private func classify(defaultInput: AudioDeviceID?, isAlive: Bool = true, _ device: InputDevice) -> HALInput.Change {
        HALInput.classify(built: mic, current: DeviceWatcher.Snapshot(defaultInput: defaultInput, isAlive: isAlive, device: device))
    }

    @Test func aNotificationThatChangesNothingKeepsTheRecording() {
        #expect(classify(defaultInput: 42, mic) == .none)
    }

    @Test func anotherDeviceOrAMissingOneIsARouteChange() {
        #expect(classify(defaultInput: 43, mic) == .route)
        #expect(classify(defaultInput: nil, mic) == .route)
        #expect(classify(defaultInput: 42, isAlive: false, mic) == .route)
    }

    @Test func aNewRateOrChannelCountOnTheSameDeviceIsFollowed() {
        var changed = mic
        changed.sampleRate = 44_100
        #expect(classify(defaultInput: 42, changed) == .format(changed))
        changed = mic
        changed.channels = 2
        #expect(classify(defaultInput: 42, changed) == .format(changed))
    }

    @Test func anUnrecordableNewFormatIsARouteChange() {
        for (rate, channels) in [(0.0, UInt32(1)), (48_000, 0), (.nan, 1)] {
            let changed = InputDevice(sampleRate: rate, channels: channels, id: 42)
            #expect(classify(defaultInput: 42, changed) == .route, "\(rate) Hz x \(channels)")
        }
    }

    @Test func aPreparedUnitIsReusedOnlyForTheSameInput() {
        #expect(HALInput.sameInput(mic, mic))
        #expect(!HALInput.sameInput(mic, InputDevice(sampleRate: 48_000, channels: 1, id: 7)))
        #expect(!HALInput.sameInput(mic, InputDevice(sampleRate: 44_100, channels: 1, id: 42)))
        #expect(!HALInput.sameInput(mic, InputDevice(sampleRate: 48_000, channels: 2, id: 42)))
    }

    @Test func startingOnADeviceThatDoesNotExistThrowsInsteadOfCrashing() {
        let sink = InputSink(deliver: { _, _, _ in Issue.record("no audio expected") }, routeChanged: {}, inputFailed: {})
        for keepsPrepared in [false, true] {
            let input = HALInput(keepsPrepared: keepsPrepared)
            let missing = InputDevice(sampleRate: 48_000, channels: 1, id: 0xDEAD)
            #expect(throws: CaptureError.self) { try input.start(device: missing, sink: sink) }
            input.stop()
        }
    }

    @Test func stopWithoutStartIsSafe() {
        HALInput(keepsPrepared: false).stop()
        HALInput(keepsPrepared: true).stop()
    }
}
