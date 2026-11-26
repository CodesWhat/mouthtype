import FluidAudio
import Foundation
import MouthtypeCore

/// Candidate recognizers for the ASR bake-off. They exist only in the bench: nothing here is in `EngineCatalog`, so the
/// app and its default engine are untouched. Each one runs the model through FluidAudio's own manager on the whole clip,
/// with no VAD gate, so the table compares the models rather than the app's pipeline around them.
enum BenchEngines {
    static let extraIDs = [ParakeetVariantEngine.ultraID, NemotronUnifiedEngine.engineID]

    static func make(id: String) throws -> any Transcriber {
        switch id {
        case ParakeetVariantEngine.ultraID: return ParakeetVariantEngine(version: .ultra, id: id, displayName: "Parakeet Ultra 0.6B (v3 post-trained)")
        case NemotronUnifiedEngine.engineID: return NemotronUnifiedEngine()
        default: return try EngineCatalog.make(id: id)
        }
    }
}

/// A Parakeet TDT checkpoint FluidAudio loads through `AsrModelVersion`, transcribed like the app's engine does.
actor ParakeetVariantEngine: MeasuredTranscriber {
    static let ultraID = "parakeet-ultra"

    nonisolated let id: String
    nonisolated let displayName: String
    nonisolated let modelDirectory: URL
    private let version: AsrModelVersion
    private var manager: AsrManager?

    init(version: AsrModelVersion, id: String, displayName: String) {
        self.version = version
        self.id = id
        self.displayName = displayName
        modelDirectory = AsrModels.defaultCacheDirectory(for: version)
    }

    func prepare() async throws { _ = try await prepareMeasured() }

    func prepareMeasured() async throws -> PrepareTimings {
        if manager != nil { return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false) }
        let clock = ContinuousClock()
        let alreadyPresent = AsrModels.modelsExist(at: modelDirectory, version: version)
        var directory = modelDirectory
        let downloadTime = try await clock.measure { directory = try await AsrModels.download(version: version) }
        let next = AsrManager(config: .default)
        let loadTime = try await clock.measure {
            let models = try await AsrModels.load(from: directory, version: version)
            try await next.loadModels(models)
            var state = TdtDecoderState.make(decoderLayers: await next.decoderLayerCount)
            _ = try await next.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state, language: nil)
        }
        manager = next
        return PrepareTimings(downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds, loadSeconds: loadTime.seconds, downloaded: !alreadyPresent)
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        guard let manager else { throw EngineError.notPrepared(id: id) }
        let start = ContinuousClock.now
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: nil)
        return Transcription(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines), processingSeconds: (ContinuousClock.now - start).seconds,
            engineID: id, modelRevision: "FluidInference/parakeet-ultra-coreml")
    }
}

/// NVIDIA Nemotron Unified ASR 0.6B in its offline mode (15 s windows, int8 encoder), English prompt. The same checkpoint
/// also streams, which is what a live preview would use; the bake-off measures the offline pass only.
actor NemotronUnifiedEngine: MeasuredTranscriber {
    static let engineID = "nemotron-unified"

    nonisolated let id = "nemotron-unified"
    nonisolated let displayName = "Nemotron Unified ASR 0.6B (offline, en)"
    nonisolated let modelDirectory: URL
    private let manager: UnifiedAsrManager
    private var loaded = false

    init() {
        let config = UnifiedConfig(family: .nemotronMultilingual(.en))
        manager = UnifiedAsrManager(config: config)
        modelDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("FluidAudio/Models", isDirectory: true)
            .appendingPathComponent("nemotron-labs-unified-asr-0.6b-coreml/coreml", isDirectory: true)
    }

    func prepare() async throws { _ = try await prepareMeasured() }

    func prepareMeasured() async throws -> PrepareTimings {
        if loaded { return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false) }
        let alreadyPresent = FileManager.default.fileExists(atPath: modelDirectory.path)
        let clock = ContinuousClock()
        let time = try await clock.measure {
            try await manager.loadModels()
            _ = try await manager.transcribe([Float](repeating: 0, count: 16_000))
        }
        loaded = true
        // FluidAudio downloads and loads in one call, so the split is not observable; the whole time is reported as load.
        return PrepareTimings(downloadSeconds: 0, loadSeconds: time.seconds, downloaded: !alreadyPresent)
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        guard loaded else { throw EngineError.notPrepared(id: id) }
        let start = ContinuousClock.now
        let text = try await manager.transcribe(samples)
        return Transcription(
            text: text.trimmingCharacters(in: .whitespacesAndNewlines), processingSeconds: (ContinuousClock.now - start).seconds,
            engineID: id, modelRevision: "FluidInference/nemotron-labs-unified-asr-0.6b-coreml")
    }
}
