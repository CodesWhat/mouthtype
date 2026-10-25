import FluidAudio
import Foundation
import os

public actor ParakeetEngine: MeasuredTranscriber, PreparationReporting, SpeechPreview, VocabularyBiasing {
    static let v3ID = "parakeet-tdt-v3"
    static let v3DisplayName = "Parakeet TDT 0.6B v3 (multilingual)"
    static let v2ID = "parakeet-tdt-v2"
    static let v2DisplayName = "Parakeet TDT 0.6B v2 (English)"

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL

    /// Download size of each model FluidAudio fetches, in the order it fetches them: preprocessor, encoder, decoder, joint.
    /// From the Hugging Face repo trees, so the bar has a total before the first byte arrives.
    static func downloadStageBytes(for version: AsrModelVersion) -> [Int64] {
        switch version {
        case .v2: [300_000, 446_200_000, 14_400_000, 3_500_000]
        default: [500_000, 446_200_000, 23_600_000, 12_700_000]
        }
    }

    private let version: AsrModelVersion
    private var manager: AsrManager?
    private var loadedModels: AsrModels?
    private var previewManager: AsrManager?
    private let inference = ParakeetInferenceGate()
    private var speechDetector: VadManager?
    private let booster: VocabularyBooster

    init(version: AsrModelVersion) {
        ModelPins.installFluidAudioRevisions()
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
        let ctc = CtcModelStore()
        booster = VocabularyBooster(
            prepare: { bias, report in
                let models = try await ctc.load(report: report)
                return try await FluidVocabularyRescorer.make(bias: bias, models: models)
            },
            release: { await ctc.release() }
        )
    }

    /// Opt-in. A non-empty bias downloads and loads the small CTC model in the background and boosts later takes
    /// once it is ready; nil releases it. A failure leaves recognition unboosted.
    public func setVocabularyBias(_ bias: VocabularyBias?) async {
        await setVocabularyBias(bias, settleWithin: nil)
    }

    /// With `settleWithin`, a changed vocabulary also waits up to that long for its model, so the take it is set for
    /// is boosted. Without one the build runs fully in the background.
    public func setVocabularyBias(_ bias: VocabularyBias?, settleWithin: Duration?) async {
        await booster.setBias(bias, settleWithin: settleWithin)
    }

    /// Resolves once the boost model for the current vocabulary is ready or has failed. True when it is ready.
    /// The app never waits on this; the bench does, so a timed run starts with the model loaded.
    public func awaitVocabularyBoost() async -> Bool {
        await booster.waitUntilSettled()
        return await booster.isReady
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
        await ModelCacheAdoption.adoptCache(of: version == .v2 ? .parakeetV2 : .parakeetV3, pin: version == .v2 ? ModelPins.parakeetV2 : ModelPins.parakeetV3)
        await ModelCacheAdoption.adoptCache(of: .vad, pin: ModelPins.sileroVAD)
        let alreadyPresent = AsrModels.modelsExist(at: modelDirectory, version: version)
        let tracker = OSAllocatedUnfairLock(initialState: StagedDownloadTracker(stageBytes: Self.downloadStageBytes(for: version)))
        if alreadyPresent {
            await report?(.cached)
        } else {
            await report?(.progress(tracker.withLock { $0.initial }))
        }

        var directory = modelDirectory
        let downloadTime = try await clock.measure {
            directory = try await AsrModels.download(
                version: version,
                progressHandler: { progress in
                    guard let report else { return }
                    let event: StagedDownloadTracker.Event
                    switch progress.phase {
                    case .listing: event = .listing
                    case .downloading: event = .downloading
                    case let .compiling(modelName): event = modelName.isEmpty ? .finished : .compiling
                    }
                    let (update, complete) = tracker.withLock { ($0.update(fraction: progress.fractionCompleted, event: event), $0.isComplete) }
                    // Compiling one model while the next still downloads is not the compile stage the user waits on.
                    let stage: EnginePreparation = complete ? .compiling : .progress(update)
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
            newDetector = try await VadManager(
                config: VadConfig(defaultThreshold: 0.5),
                progressHandler: { progress in
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
            _ = try await newManager.transcribe([Float](repeating: 0, count: 16_000), decoderState: &state, language: version == .v3 ? DictationLanguageRequest.english.parakeetHint : nil)
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
        try await preview(samples: samples, language: .english)
    }

    public func preview(samples: [Float], language: DictationLanguageRequest) async throws -> String? {
        guard !language.possibleLanguages.contains(where: \.requiresWhisper) else { return nil }
        guard samples.count >= 32_000 else { return nil }
        guard let loadedModels, let speechDetector else { throw EngineError.notPrepared(id: id) }
        return try await inference.withPreview(
            prepare: {
                try await self.preparePreview(samples: samples, models: loadedModels, detector: speechDetector)
            },
            predict: { input in
                try await self.predictPreview(input, language: language)
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

    private func predictPreview(_ input: PreparedPreview?, language: DictationLanguageRequest) async throws -> String? {
        try Task.checkCancellation()
        guard var input else { return "" }
        let result = try await input.manager.transcribe(input.samples, decoderState: &input.state, language: version == .v3 ? language.parakeetHint : nil)
        try Task.checkCancellation()
        return result.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func transcribe(samples: [Float]) async throws -> Transcription {
        try await transcribe(samples: samples, language: .english)
    }

    public func transcribe(samples: [Float], language: DictationLanguageRequest) async throws -> Transcription {
        if let unsupported = language.possibleLanguages.first(where: \.requiresWhisper) {
            throw EngineError.unsupportedLanguage(id: id, language: unsupported)
        }
        guard let manager, let speechDetector else { throw EngineError.notPrepared(id: id) }
        let startedAt = ContinuousClock.now
        return try await inference.withFinal {
            try await self.transcribeWithAccess(
                samples: samples, request: language, manager: manager, detector: speechDetector, startedAt: startedAt)
        }
    }

    private func transcribeWithAccess(
        samples: [Float], request: DictationLanguageRequest, manager: AsrManager, detector: VadManager,
        startedAt: ContinuousClock.Instant
    ) async throws -> Transcription {
        let clock = ContinuousClock()
        let start = startedAt
        // VAD and ASR run together. VAD stays the filter for noise the recogniser would turn into words: with no speech
        // the ASR result is dropped, and an ASR failure only matters when there was speech.
        let language = version == .v3 ? request.parakeetHint : nil
        async let asr: Result<ASRResult, Error> = {
            do {
                var state = TdtDecoderState.make(decoderLayers: await manager.decoderLayerCount)
                return .success(try await manager.transcribe(samples, decoderState: &state, language: language))
            } catch {
                return .failure(error)
            }
        }()
        let speech = try await detector.process(samples)
        guard speech.contains(where: { $0.isVoiceActive }) else {
            return Transcription(
                text: "",
                processingSeconds: (clock.now - start).seconds,
                engineID: id,
                modelRevision: version == .v2 ? Repo.parakeetV2.rawValue : Repo.parakeetV3.rawValue
            )
        }
        let result = try await asr.get()
        let units = (result.tokenTimings ?? []).map {
            SubwordUnit(text: $0.token, start: $0.startTime, end: $0.endTime, confidence: $0.confidence)
        }
        var text = result.text.trimmingCharacters(in: .whitespacesAndNewlines)
        var words = WordAssembly.assemble(units)
        var applied: [String]?
        if let timings = result.tokenTimings,
            request.allowsVocabularyBoost,
            let boosted = await booster.boost(text: result.text, tokenTimings: timings, samples: samples)
        {
            // Replaced spans take the times of the words they replaced; untouched words keep theirs.
            text = boosted.text
            words = VocabularyBooster.realign(words, to: boosted.text)
            applied = boosted.appliedTerms
        }
        return Transcription(
            text: text,
            words: words,
            confidence: result.confidence,
            processingSeconds: (clock.now - start).seconds,
            engineID: id,
            modelRevision: version == .v2 ? Repo.parakeetV2.rawValue : Repo.parakeetV3.rawValue,
            boostTermsApplied: applied
        )
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
