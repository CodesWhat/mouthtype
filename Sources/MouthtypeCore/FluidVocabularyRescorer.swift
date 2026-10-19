import FluidAudio
import Foundation
import Synchronization

/// How strict the rescorer is. The defaults are the ones the app ships; the bench sets `current` to sweep them.
public struct VocabularyBoostTuning: Sendable, Equatable {
    /// Lowest string similarity between a spoken word and a saved spelling for a replacement. FluidAudio's own
    /// default is 0.52, which replaced ordinary words with saved names in 14 of 50 test clips; 0.70 replaced none
    /// at 10, 50 and 200 terms. See docs/evals/vocabulary-boosting-2026-10.md.
    public var minSimilarity: Float
    public var minCombinedConfidence: Float
    /// Terms with fewer CTC tokens than this get a smaller boost; 1 turns the taper off.
    public var shortTermTaperPivot: Int
    public var minTermLength: Int

    public init(
        minSimilarity: Float = 0.70,
        minCombinedConfidence: Float = ContextBiasingConstants.defaultMinCombinedConfidence,
        shortTermTaperPivot: Int = 1,
        minTermLength: Int = 3
    ) {
        self.minSimilarity = minSimilarity
        self.minCombinedConfidence = minCombinedConfidence
        self.shortTermTaperPivot = shortTermTaperPivot
        self.minTermLength = minTermLength
    }

    public static let standard = VocabularyBoostTuning()

    private static let state = Mutex(VocabularyBoostTuning.standard)

    /// Read when a session is built. Only the bench writes it.
    public static var current: VocabularyBoostTuning {
        get { state.withLock { $0 } }
        set { state.withLock { $0 = newValue } }
    }
}

/// FluidAudio's CTC keyword spotter plus constrained rescorer, behind `VocabularyRescoring`.
struct FluidVocabularyRescorer: VocabularyRescoring {
    let session: VocabularyBoostingSession

    /// Terms as FluidAudio vocabulary entries: the written form is the text, saved heard forms are aliases.
    static func context(for bias: VocabularyBias, tuning: VocabularyBoostTuning = .current) -> CustomVocabularyContext {
        CustomVocabularyContext(
            terms: bias.entries.map { CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases) },
            minSimilarity: tuning.minSimilarity,
            minCombinedConfidence: tuning.minCombinedConfidence,
            minTermLength: tuning.minTermLength
        )
    }

    /// The spotter-anchored acoustic rescue is off: upstream measured far fewer short-term false positives without it.
    static func rescorerConfig(tuning: VocabularyBoostTuning = .current) -> VocabularyRescorer.Config {
        VocabularyRescorer.Config(shortTermCbwTaperPivot: tuning.shortTermTaperPivot, spotterRescueEnabled: false)
    }

    static func make(bias: VocabularyBias, models: CtcModels) async throws -> FluidVocabularyRescorer {
        FluidVocabularyRescorer(session: try await VocabularyBoostingSession(
            vocabulary: context(for: bias), ctcModels: models, config: rescorerConfig()
        ))
    }

    func rescore(text: String, tokenTimings: [TokenTiming], samples: [Float]) async -> VocabularyRescore? {
        guard let output = await session.rescore(text: text, tokenTimings: tokenTimings, audioSamples: samples) else { return nil }
        var seen = Set<String>()
        let applied = output.replacements.filter(\.shouldReplace).compactMap(\.replacementWord)
            .filter { seen.insert($0.lowercased()).inserted }
        return VocabularyRescore(text: output.text, wasModified: output.wasModified, appliedTerms: applied)
    }
}

/// Holds a loaded model so a vocabulary change rebuilds only the session, not the 100 MB model.
actor ModelStore<Model: Sendable> {
    private let loader: @Sendable (@Sendable (VocabularyBoostStatus) -> Void) async throws -> Model
    private var models: Model?
    /// Bumped by `release()`, so a load that was in flight across one doesn't leave the model resident.
    private var releases = 0

    init(loader: @escaping @Sendable (@Sendable (VocabularyBoostStatus) -> Void) async throws -> Model) {
        self.loader = loader
    }

    func load(report: @escaping @Sendable (VocabularyBoostStatus) -> Void) async throws -> Model {
        if let models { return models }
        let generation = releases
        let loaded = try await loader(report)
        if generation == releases, !Task.isCancelled { models = loaded }
        return loaded
    }

    func release() {
        releases += 1
        models = nil
    }

    var isLoaded: Bool { models != nil }
}

typealias CtcModelStore = ModelStore<CtcModels>

extension ModelStore where Model == CtcModels {
    init() {
        self.init(loader: { report in
            let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
            report(CtcModels.modelsExist(at: directory) ? .preparing : .downloading(fraction: nil))
            return try await CtcModels.downloadAndLoad(variant: .ctc110m)
        })
    }
}
