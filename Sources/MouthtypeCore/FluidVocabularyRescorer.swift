import FluidAudio
import Foundation

/// FluidAudio's CTC keyword spotter plus constrained rescorer, behind `VocabularyRescoring`.
struct FluidVocabularyRescorer: VocabularyRescoring {
    let session: VocabularyBoostingSession

    /// Terms as FluidAudio vocabulary entries: the written form is the text, saved heard forms are aliases.
    static func context(for bias: VocabularyBias) -> CustomVocabularyContext {
        CustomVocabularyContext(terms: bias.entries.map {
            CustomVocabularyTerm(text: $0.text, aliases: $0.aliases.isEmpty ? nil : $0.aliases)
        })
    }

    /// The spotter-anchored acoustic rescue is off: upstream measured far fewer short-term false positives without it.
    static let rescorerConfig = VocabularyRescorer.Config(spotterRescueEnabled: false)

    static func make(bias: VocabularyBias, models: CtcModels) async throws -> FluidVocabularyRescorer {
        FluidVocabularyRescorer(session: try await VocabularyBoostingSession(
            vocabulary: context(for: bias), ctcModels: models, config: rescorerConfig
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

/// Holds the loaded CTC model so a vocabulary change rebuilds only the session, not the 100 MB model.
actor CtcModelStore {
    private var models: CtcModels?

    func load(report: @Sendable (VocabularyBoostStatus) -> Void) async throws -> CtcModels {
        if let models { return models }
        let directory = CtcModels.defaultCacheDirectory(for: .ctc110m)
        report(CtcModels.modelsExist(at: directory) ? .preparing : .downloading(fraction: nil))
        let loaded = try await CtcModels.downloadAndLoad(variant: .ctc110m)
        models = loaded
        return loaded
    }

    func release() { models = nil }
}
