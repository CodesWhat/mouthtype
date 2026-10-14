import FluidAudio
import Foundation

public actor ParakeetEngine: MeasuredTranscriber, PreparationReporting {
    static let v3ID = "parakeet-tdt-v3"
    static let v3DisplayName = "Parakeet TDT 0.6B v3 (multilingual)"
    static let v2ID = "parakeet-tdt-v2"
    static let v2DisplayName = "Parakeet TDT 0.6B v2 (English)"

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL

    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var speechDetector: VadManager?

    init(version: AsrModelVersion) {
        self.version = version
        switch version {
        case .v2:
            id = Self.v2ID
            displayName = Self.v2DisplayName
        default:
            id = Self.v3ID
            displayName = Self.v3DisplayName
        }
        modelDirectory = AsrModels.defaultCacheDirectory(for: version)
    }

    public func prepare() async throws {
        _ = try await prepareMeasured()
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        try await prepareMeasured(report: nil)
    }

    public func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws {
        _ = try await prepareMeasured(report: report)
    }

    private func prepareMeasured(report: (@Sendable (EnginePreparation) async -> Void)?) async throws -> PrepareTimings {
        if manager != nil, speechDetector != nil {
            return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
        }
        let clock = ContinuousClock()
        let alreadyPresent = AsrModels.modelsExist(at: modelDirectory, version: version)
        if !alreadyPresent { await report?(.downloading(fraction: 0)) }

        var directory = modelDirectory
        let downloadTime = try await clock.measure {
            directory = try await AsrModels.download(version: version, progressHandler: { progress in
                guard let report else { return }
                let stage: EnginePreparation
                switch progress.phase {
                case .listing: stage = .downloading(fraction: 0)
                case .downloading: stage = .downloading(fraction: progress.fractionCompleted)
                case .compiling: stage = .compiling
                }
                Task { await report(stage) }
            })
        }
        await report?(.loadingModel)
        let newManager = AsrManager(config: .default)
        var newDetector: VadManager?
        let loadTime = try await clock.measure {
            let models = try await AsrModels.load(from: directory, version: version)
            try await newManager.loadModels(models)
            newDetector = try await VadManager(config: VadConfig(defaultThreshold: 0.5), progressHandler: { progress in
                guard let report else { return }
                let stage: EnginePreparation
                switch progress.phase {
                case .listing: stage = .downloading(fraction: 0)
                case .downloading: stage = .downloading(fraction: progress.fractionCompleted)
                case .compiling: stage = .compiling
                }
                Task { await report(stage) }
            })
            var state = TdtDecoderState.make(decoderLayers: await newManager.decoderLayerCount)
            _ = try await newManager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state)
        }
        manager = newManager
        speechDetector = newDetector
        return PrepareTimings(
            downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds,
            loadSeconds: loadTime.seconds,
            downloaded: !alreadyPresent
        )
    }

    public func transcribe(samples: [Float]) async throws -> Transcription {
        guard let manager, let speechDetector else { throw EngineError.notPrepared(id: id) }
        let clock = ContinuousClock()
        let start = clock.now
        let speech = try await speechDetector.process(samples)
        guard speech.contains(where: { $0.isVoiceActive }) else {
            return Transcription(
                text: "",
                processingSeconds: (clock.now - start).seconds,
                engineID: id,
                modelRevision: version == .v2 ? Repo.parakeetV2.rawValue : Repo.parakeetV3.rawValue
            )
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state)
        let elapsed = (clock.now - start).seconds
        let units = (result.tokenTimings ?? []).map {
            SubwordUnit(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }
        return Transcription(
            text: result.text.trimmingCharacters(in: .whitespacesAndNewlines),
            words: WordAssembly.assemble(units),
            confidence: result.confidence,
            processingSeconds: elapsed,
            engineID: id,
            modelRevision: version == .v2 ? Repo.parakeetV2.rawValue : Repo.parakeetV3.rawValue
        )
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
