import FluidAudio
import Foundation

public actor ParakeetEngine: MeasuredTranscriber, PreparationReporting, SpeechPreview {
    static let v3ID = "parakeet-tdt-v3"
    static let v3DisplayName = "Parakeet TDT 0.6B v3 (multilingual)"
    static let v2ID = "parakeet-tdt-v2"
    static let v2DisplayName = "Parakeet TDT 0.6B v2 (English)"

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL

    private let version: AsrModelVersion
    private let language: Language?
    private var manager: AsrManager?
    private var loadedModels: AsrModels?
    private var previewManager: AsrManager?
    private let inference = ParakeetInferenceGate()
    private var speechDetector: VadManager?

    init(version: AsrModelVersion, language: Language? = nil) {
        self.version = version
        self.language = language
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
            loadedModels = models
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
            _ = try await newManager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state, language: version == .v3 ? language : nil)
        }
        manager = newManager
        speechDetector = newDetector
        return PrepareTimings(
            downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds,
            loadSeconds: loadTime.seconds,
            downloaded: !alreadyPresent
        )
    }

    public func preview(samples: [Float]) async throws -> String? {
        guard samples.count >= 32_000 else { return nil }
        guard let loadedModels, let speechDetector else { throw EngineError.notPrepared(id: id) }
        return try await inference.withPreview(prepare: {
            try await self.preparePreview(samples: samples, models: loadedModels, detector: speechDetector)
        }, predict: { input in
            try await self.predictPreview(input)
        })
    }

    private struct PreparedPreview: Sendable {
        var manager: AsrManager
        var state: TdtDecoderState
        var samples: [Float]
    }

    private func preparePreview(samples: [Float], models: AsrModels, detector: VadManager) async throws -> PreparedPreview? {
        try Task.checkCancellation()
        let window = Array(samples.suffix(128_000))
        let speech = try await detector.process(window)
        try Task.checkCancellation()
        guard speech.contains(where: { $0.isVoiceActive }) else { return nil }
        if previewManager == nil {
            let preview = AsrManager(config: .default)
            try await preview.loadModels(models)
            previewManager = preview
        }
        guard let previewManager else { return nil }
        let state = TdtDecoderState.make(decoderLayers: await previewManager.decoderLayerCount)
        return PreparedPreview(manager: previewManager, state: state, samples: window)
    }

    private func predictPreview(_ input: PreparedPreview?) async throws -> String? {
        try Task.checkCancellation()
        guard var input else { return "" }
        let result = try await input.manager.transcribe(input.samples, decoderState: &input.state, language: version == .v3 ? language : nil)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(samples: [Float]) async throws -> Transcription {
        guard let manager, let speechDetector else { throw EngineError.notPrepared(id: id) }
        let startedAt = ContinuousClock.now
        return try await inference.withFinal {
            try await self.transcribeWithAccess(samples: samples, manager: manager, detector: speechDetector, startedAt: startedAt)
        }
    }

    private func transcribeWithAccess(samples: [Float], manager: AsrManager, detector: VadManager,
                                     startedAt: ContinuousClock.Instant) async throws -> Transcription {
        let clock = ContinuousClock()
        let start = startedAt
        let speech = try await detector.process(samples)
        guard speech.contains(where: { $0.isVoiceActive }) else {
            return Transcription(
                text: "",
                processingSeconds: (clock.now - start).seconds,
                engineID: id,
                modelRevision: version == .v2 ? Repo.parakeetV2.rawValue : Repo.parakeetV3.rawValue
            )
        }
        var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
        let result = try await manager.transcribe(samples, decoderState: &state, language: version == .v3 ? language : nil)
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
