import AVFoundation
import Foundation
import MouthtypeCore

struct MacAudioFileDecoder: AudioFileDecoding {
    static let extensions = ["wav", "wave", "aif", "aiff", "m4a"]
    private static let chunkFrames: AVAudioFrameCount = 4_096

    func decode(_ url: URL, limits: AudioFileLimits) async throws -> DecodedAudioFile {
        try Task.checkCancellation()
        guard url.isFileURL, Self.extensions.contains(url.pathExtension.lowercased()) else {
            throw AudioFileError.unsupportedFormat
        }
        do {
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true, let size = values.fileSize, size > 0 else { throw AudioFileError.invalidAudio }
            guard size <= limits.maximumSourceBytes else { throw AudioFileError.tooLarge }
            let file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false)
            let format = file.processingFormat
            guard format.sampleRate.isFinite, format.sampleRate > 0, format.sampleRate <= 384_000,
                  (1...8).contains(format.channelCount), file.length > 0 else { throw AudioFileError.invalidAudio }
            let duration = Double(file.length) / format.sampleRate
            guard duration.isFinite, duration <= limits.maximumSeconds else { throw AudioFileError.tooLong }
            guard let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
                  let converter = AVAudioConverter(from: format, to: target),
                  let input = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: Self.chunkFrames),
                  let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: Self.chunkFrames) else {
                throw AudioFileError.unsupportedFormat
            }
            var samples: [Float] = []
            samples.reserveCapacity(min(limits.maximumSamples, Int(ceil(duration * 16_000)) + 1_024))
            var ended = false
            var readError: Error?
            while true {
                try Task.checkCancellation()
                let previous = file.framePosition
                output.frameLength = 0
                var conversionError: NSError?
                let status = converter.convert(to: output, error: &conversionError) { requested, state in
                    if ended || file.framePosition >= file.length || Task.isCancelled {
                        ended = true
                        state.pointee = .endOfStream
                        return nil
                    }
                    do {
                        input.frameLength = 0
                        try file.read(into: input, frameCount: min(Self.chunkFrames, max(1, requested)))
                        if input.frameLength == 0 {
                            ended = true
                            state.pointee = .endOfStream
                            return nil
                        }
                        state.pointee = .haveData
                        return input
                    } catch {
                        readError = error
                        ended = true
                        state.pointee = .endOfStream
                        return nil
                    }
                }
                try Task.checkCancellation()
                guard readError == nil, conversionError == nil, status != .error else { throw AudioFileError.invalidAudio }
                let count = Int(output.frameLength)
                guard count <= limits.maximumSamples - samples.count else { throw AudioFileError.tooLong }
                if count > 0 {
                    guard let channel = output.floatChannelData?[0] else { throw AudioFileError.invalidAudio }
                    for value in UnsafeBufferPointer(start: channel, count: count) {
                        guard value.isFinite else { throw AudioFileError.invalidAudio }
                        samples.append(min(1, max(-1, value)))
                    }
                }
                if status == .endOfStream { break }
                guard count > 0 || file.framePosition > previous else { throw AudioFileError.invalidAudio }
            }
            guard !samples.isEmpty else { throw AudioFileError.empty }
            return DecodedAudioFile(samples: samples, durationSeconds: duration)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as AudioFileError {
            throw error
        } catch {
            throw AudioFileError.invalidAudio
        }
    }
}
