import AVFoundation
import Foundation

public enum AudioLoadingError: Error, LocalizedError {
    case converterUnavailable(from: String)
    case conversionFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .converterUnavailable(format): return "No converter from \(format) to 16 kHz mono Float32"
        case let .conversionFailed(reason): return "Audio conversion failed: \(reason)"
        }
    }
}

public enum AudioLoading {
    public static let targetSampleRate: Double = 16_000

    public static func loadSamples(from url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url)
        let frameCount = AVAudioFrameCount(file.length)
        guard frameCount > 0,
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: frameCount)
        else {
            return []
        }
        try file.read(into: buffer)
        return try samples16kMono(from: buffer)
    }

    /// Converts any PCM buffer (any rate, channel count or sample format) to 16 kHz mono Float32 samples.
    public static func samples16kMono(from buffer: AVAudioPCMBuffer) throws -> [Float] {
        guard
            let targetFormat = AVAudioFormat(
                commonFormat: .pcmFormatFloat32,
                sampleRate: targetSampleRate,
                channels: 1,
                interleaved: false
            )
        else {
            throw AudioLoadingError.conversionFailed("could not build target format")
        }

        let inputFormat = buffer.format
        if inputFormat.commonFormat == .pcmFormatFloat32,
            inputFormat.sampleRate == targetSampleRate,
            inputFormat.channelCount == 1,
            let channel = buffer.floatChannelData?[0]
        {
            return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: targetFormat) else {
            throw AudioLoadingError.converterUnavailable(from: inputFormat.description)
        }

        let ratio = targetSampleRate / inputFormat.sampleRate
        let chunkCapacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 1024
        guard let chunk = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: chunkCapacity) else {
            throw AudioLoadingError.conversionFailed("could not allocate output buffer")
        }

        var samples: [Float] = []
        samples.reserveCapacity(Int(chunkCapacity))
        var inputConsumed = false

        while true {
            chunk.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: chunk, error: &conversionError) { _, inputStatus in
                if inputConsumed {
                    inputStatus.pointee = .endOfStream
                    return nil
                }
                inputConsumed = true
                inputStatus.pointee = .haveData
                return buffer
            }
            if status == .error {
                throw AudioLoadingError.conversionFailed(conversionError?.localizedDescription ?? "unknown error")
            }
            if chunk.frameLength > 0, let channel = chunk.floatChannelData?[0] {
                samples.append(contentsOf: UnsafeBufferPointer(start: channel, count: Int(chunk.frameLength)))
            }
            if status == .endOfStream || chunk.frameLength == 0 {
                break
            }
        }
        return samples
    }
}
