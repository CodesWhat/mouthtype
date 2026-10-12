import AVFoundation
import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioLoadingTests {
    private func writeSine(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels))
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<Int(channels) {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.5 * Float(sin(2 * Double.pi * 440 * Double(frame) / sampleRate))
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
        ])
        try file.write(from: buffer)
    }

    private func temporaryDirectory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func stereo44kWavBecomes16kMono() throws {
        let dir = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("sine.wav")
        try writeSine(to: url, sampleRate: 44_100, channels: 2, seconds: 1.0)

        let samples = try AudioLoading.loadSamples(from: url)

        #expect(abs(samples.count - 16_000) <= 64)
        let peak = samples.map { abs($0) }.max() ?? 0
        #expect(peak > 0.3 && peak <= 1.0)
    }

    @Test func bufferConversionResamplesAndDownmixes() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let frames: AVAudioFrameCount = 24_000
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        for channel in 0..<2 {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(frames) {
                data[frame] = 0.25
            }
        }

        let samples = try AudioLoading.samples16kMono(from: buffer)

        #expect(abs(samples.count - 8_000) <= 64)
    }

    @Test func alreadyTargetFormatPassesThrough() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 100))
        buffer.frameLength = 100
        let data = try #require(buffer.floatChannelData?[0])
        for frame in 0..<100 { data[frame] = Float(frame) / 100 }

        let samples = try AudioLoading.samples16kMono(from: buffer)

        #expect(samples.count == 100)
        #expect(samples[50] == 0.5)
    }
}
