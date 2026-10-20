import ArgumentParser
import Foundation
import MouthtypeCore

/// `mouthtype-bench boost-eval`: measures Parakeet vocabulary boosting on clips from `scripts/boost-eval-clips.py`.
/// One process, so the RSS it reports is the app's engine plus the CTC model and nothing else.
struct BoostEvalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "boost-eval",
        abstract: "Measure recall, false replacements, latency and memory of Parakeet vocabulary boosting."
    )

    @Option(help: "Directory with manifest.json and the WAV clips.") var clips: String = "/tmp/mouthtype-boost-eval"
    @Option(help: "Engine id (a Parakeet engine).") var engine: String = "parakeet-tdt-v3"
    @Option(help: "JSON result path.") var out: String = "/tmp/mouthtype-boost-eval/results.json"
    @Option(help: "Rescorer minimum string similarity (default is the shipped value).") var minSimilarity: Float?
    @Option(help: "Rescorer minimum combined confidence.") var minCombined: Float?
    @Option(help: "Short-term boost taper pivot in tokens; 1 is off.") var taperPivot: Int?
    @Option(help: "Minimum term length in characters.") var minTermLength: Int?
    @Flag(help: "Run only the 50 term plain-sentence pass, not the 10 and 200 term ones.") var quick = false
    @Option(help: "Timed passes per clip for the latency numbers; the median is reported.") var passes: Int = 3

    struct Clip: Codable {
        var file: String
        var group: String
        var voice: String
        var text: String
        var targets: [String]
    }

    struct Manifest: Codable {
        var clips: [Clip]
        var distractors: [String]
    }

    struct Pass: Codable {
        var label: String
        var texts: [String: String]
        /// Median over `passes` timed runs, per clip, in milliseconds.
        var medianMs: [String: Double]
    }

    struct Result: Codable {
        var engine: String
        var passes: Int
        var rssMBBeforeBoostModel: Double
        var residentMBBeforeBoostModel: Double
        var residentMBAfterBoostModel: Double
        var rssMBAfterBoostModel: Double
        var peakMBAfterRuns: Double
        var boostModelSeconds: Double
        var runs: [Pass]
        var manifest: Manifest
    }

    func run() async throws {
        var tuning = VocabularyBoostTuning.standard
        if let minSimilarity { tuning.minSimilarity = minSimilarity }
        if let minCombined { tuning.minCombinedConfidence = minCombined }
        if let taperPivot { tuning.shortTermTaperPivot = taperPivot }
        if let minTermLength { tuning.minTermLength = minTermLength }
        VocabularyBoostTuning.current = tuning
        print("tuning \(tuning)")
        let directory = URL(fileURLWithPath: clips)
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        let transcriber = try EngineCatalog.make(id: engine, englishHint: true)
        guard let parakeet = transcriber as? ParakeetEngine else { throw ValidationError("\(engine) is not a Parakeet engine.") }
        try await parakeet.prepare()
        var audio: [String: [Float]] = [:]
        for clip in manifest.clips {
            audio[clip.file] = try AudioLoading.loadSamples(from: directory.appendingPathComponent(clip.file))
        }
        _ = try await parakeet.transcribe(samples: audio[manifest.clips[0].file] ?? [])

        var runs: [Pass] = []
        func measure(_ label: String, _ subset: [Clip]) async throws {
            var texts: [String: String] = [:]
            var times: [String: [Double]] = [:]
            for round in 0..<passes {
                for clip in subset {
                    let result = try await parakeet.transcribe(samples: audio[clip.file] ?? [])
                    if round == 0 { texts[clip.file] = result.text }
                    times[clip.file, default: []].append(result.processingSeconds * 1000)
                }
            }
            runs.append(Pass(label: label, texts: texts, medianMs: times.mapValues { Stats.median($0) }))
            print("pass \(label): \(subset.count) clips")
        }

        let names = manifest.clips.filter { $0.group == "names" }
        let plain = manifest.clips.filter { $0.group == "plain" }
        let targets = Array(NSOrderedSet(array: names.flatMap(\.targets))) as? [String] ?? []

        await parakeet.setVocabularyBias(nil)
        try await measure("baseline", manifest.clips)

        let rssBefore = Double(ProcessMemory.currentFootprintBytes()) / 1_048_576
        let residentBefore = Double(ProcessMemory.residentBytes()) / 1_048_576
        let loadStart = ContinuousClock.now
        await parakeet.setVocabularyBias(VocabularyBias(terms: targets))
        guard await parakeet.awaitVocabularyBoost() else { throw ValidationError("The boost model did not become ready.") }
        let boostSeconds = (ContinuousClock.now - loadStart).seconds
        let rssAfter = Double(ProcessMemory.currentFootprintBytes()) / 1_048_576
        let residentAfter = Double(ProcessMemory.residentBytes()) / 1_048_576
        print("boost model ready in \(String(format: "%.1f", boostSeconds)) s, footprint \(Int(rssBefore)) -> \(Int(rssAfter)) MB, resident \(Int(residentBefore)) -> \(Int(residentAfter)) MB")

        try await measure("names-targets", names)
        let padded = targets + manifest.distractors.prefix(max(0, 50 - targets.count))
        await parakeet.setVocabularyBias(VocabularyBias(terms: Array(padded)))
        _ = await parakeet.awaitVocabularyBoost()
        try await measure("names-targets-plus-distractors-50", names)

        for size in quick ? [50] : [10, 50, 200] {
            await parakeet.setVocabularyBias(VocabularyBias(terms: Array(manifest.distractors.prefix(size))))
            guard await parakeet.awaitVocabularyBoost() else { throw ValidationError("Session for \(size) terms failed.") }
            try await measure("plain-distractors-\(size)", plain)
        }

        let result = Result(
            engine: engine, passes: passes, rssMBBeforeBoostModel: rssBefore, residentMBBeforeBoostModel: residentBefore,
            residentMBAfterBoostModel: residentAfter, rssMBAfterBoostModel: rssAfter,
            peakMBAfterRuns: Double(ProcessMemory.peakFootprintBytes()) / 1_048_576, boostModelSeconds: boostSeconds,
            runs: runs, manifest: manifest
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(result).write(to: URL(fileURLWithPath: out))
        print("wrote \(out)")
    }
}
