import AVFoundation
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct AudioFileDecoderTests {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-file-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func tone(_ url: URL, compressed: Bool = false, seconds: Double = 0.25) throws {
        let rate = 44_100.0
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 2))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(rate * seconds)))
        buffer.frameLength = buffer.frameCapacity
        for channel in 0..<2 {
            let data = try #require(buffer.floatChannelData?[channel])
            for frame in 0..<Int(buffer.frameLength) { data[frame] = Float(sin(2 * Double.pi * 440 * Double(frame) / rate)) * 0.5 }
        }
        let settings: [String: Any] = compressed
            ? [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVEncoderBitRateKey: 128_000]
            : [AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 16, AVLinearPCMIsFloatKey: false]
        let file = try AVAudioFile(forWriting: url, settings: settings)
        try file.write(from: buffer)
    }

    @Test(arguments: ["wav", "aiff", "m4a"])
    func importsSupportedFormatsWithResamplingAndPreservesOriginal(ext: String) async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("recording.\(ext)")
        try tone(source, compressed: ext == "m4a")
        let metadata = try AVAudioFile(forReading: source)
        #expect(metadata.fileFormat.streamDescription.pointee.mFormatID == (ext == "m4a" ? kAudioFormatMPEG4AAC : kAudioFormatLinearPCM))
        let before = try Data(contentsOf: source)
        let result = try await MacAudioFileDecoder().decode(source, limits: .standard)
        #expect(abs(result.durationSeconds - 0.25) < 0.1)
        #expect(abs(result.samples.count - 4_000) < 1_024)
        let allFinite = result.samples.allSatisfy { $0.isFinite }
        #expect(allFinite)
        #expect((result.samples.map { abs($0) }.max() ?? 0) > 0.2)
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func multichunkConversionKeepsDurationAndWaveformContinuous() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("longer.wav")
        try tone(source, seconds: 2)
        let result = try await MacAudioFileDecoder().decode(source, limits: .standard)
        #expect(abs(result.samples.count - 32_000) < 32)
        #expect(result.durationSeconds == 2)
        for start in stride(from: 1_000, to: 30_000, by: 4_096) {
            let window = result.samples[start..<(start + 500)]
            let crossings = zip(window, window.dropFirst()).filter { $0 < 0 && $1 >= 0 }.count
            #expect((12...15).contains(crossings))
        }
    }

    @Test func floatingPointAudioIsBoundedForTheTranscriberWithoutChangingSource() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("loud.wav")
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        do {
            let file = try AVAudioFile(forWriting: source, settings: format.settings)
            let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_000))
            buffer.frameLength = 4_000
            let samples = try #require(buffer.floatChannelData?[0])
            for i in 0..<4_000 { samples[i] = i % 2 == 0 ? 2 : -2 }
            try file.write(from: buffer)
        }
        let before = try Data(contentsOf: source)
        let result = try await MacAudioFileDecoder().decode(source, limits: .standard)
        let inRange = result.samples.allSatisfy { $0.isFinite && (-1...1).contains($0) }
        #expect(inRange)
        #expect(result.samples.contains(1) && result.samples.contains(-1))
        #expect(try Data(contentsOf: source) == before)
    }

    @Test func preflightRejectsOversizedSparseWavBeforeDecoding() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("too-long.wav")
        let byteCount = 16_000 * 601 * 2
        func little<T: FixedWidthInteger>(_ number: T) -> Data {
            var value = number.littleEndian
            return withUnsafeBytes(of: &value) { Data($0) }
        }
        var header = Data("RIFF".utf8) + little(UInt32(36 + byteCount)) + Data("WAVEfmt ".utf8)
        header += little(UInt32(16)) + little(UInt16(1)) + little(UInt16(1))
        header += little(UInt32(16_000)) + little(UInt32(32_000)) + little(UInt16(2)) + little(UInt16(16))
        header += Data("data".utf8) + little(UInt32(byteCount))
        try header.write(to: source)
        let file = try FileHandle(forWritingTo: source)
        try file.truncate(atOffset: UInt64(44 + byteCount))
        try file.close()
        let metadata = try AVAudioFile(forReading: source)
        #expect(Double(metadata.length) / metadata.processingFormat.sampleRate > 600)
        await #expect(throws: AudioFileError.tooLong) { try await MacAudioFileDecoder().decode(source, limits: .standard) }
        #expect((try source.resourceValues(forKeys: [.fileSizeKey]).fileSize) == 44 + byteCount)
    }

    @Test func invalidAndCanceledInputsNeverProduceTextOrMutateFiles() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("bad.wav")
        let bytes = Data("not audio".utf8)
        try bytes.write(to: source)
        await #expect(throws: AudioFileError.self) { try await MacAudioFileDecoder().decode(source, limits: .standard) }
        let task = Task { try await MacAudioFileDecoder().decode(source, limits: .standard) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(try Data(contentsOf: source) == bytes)
    }
    @Test func oversizedSourceIsRejectedBeforeOpeningDecoder() async throws {
        let root = try directory()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("large.wav")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(AudioFileLimits.standard.maximumSourceBytes) + 1)
        try handle.close()
        await #expect(throws: AudioFileError.tooLarge) { try await MacAudioFileDecoder().decode(source, limits: .standard) }
    }

}
