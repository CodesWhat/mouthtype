import Foundation
import WhisperKit

public actor WhisperEngine: MeasuredTranscriber {
    static let turboID = "whisper-large-v3-turbo"
    static let turboDisplayName = "Whisper large-v3 turbo"
    static let turboVariant = "large-v3-v20240930_turbo"
    static let smallEnID = "whisper-small-en"
    static let smallEnDisplayName = "Whisper small.en"
    static let smallEnVariant = "small.en"

    private static let modelRepo = "argmaxinc/whisperkit-coreml"

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL

    private let variant: String
    private var kit: WhisperKit?

    init(id: String, displayName: String, variant: String) {
        self.id = id
        self.displayName = displayName
        self.variant = variant
        modelDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/\(Self.modelRepo)/openai_whisper-\(variant)", isDirectory: true)
    }

    public func prepare() async throws {
        _ = try await prepareMeasured()
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        if kit != nil {
            return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
        }
        let clock = ContinuousClock()
        let alreadyPresent = FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc").path)

        var folder = modelDirectory
        let downloadTime = try await clock.measure {
            folder = try await WhisperKit.download(variant: variant, from: Self.modelRepo)
        }
        var loaded: WhisperKit?
        let loadTime = try await clock.measure {
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .none,
                load: true,
                download: false
            )
            loaded = try await WhisperKit(config)
        }
        kit = loaded
        return PrepareTimings(
            downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds,
            loadSeconds: loadTime.seconds,
            downloaded: !alreadyPresent
        )
    }

    public func transcribe(samples: [Float]) async throws -> String {
        guard let kit else { throw EngineError.notPrepared(id: id) }
        let options = DecodingOptions(verbose: false, task: .transcribe, language: "en", detectLanguage: false)
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
