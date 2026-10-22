import ArgumentParser
import Foundation
import MouthtypeCore
import NaturalLanguage

/// `NLLanguageRecognizer` constrained to the candidate set, the way the app's detector is.
struct BenchLanguageDetector: LanguageDetector {
    func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)] {
        guard !candidates.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0.code) }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: candidates.count)
            .compactMap { entry in DictationLanguage(code: entry.key.rawValue).map { ($0, entry.value) } }
            .sorted { $0.1 > $1.1 }
    }
}

/// Measures Thorough cleanup per language on the multilingual fixtures.
enum LanguageCleanupBench {
    /// The ship gate from the design: tier-1 languages at this share accepted and this share language-preserved.
    static let gateAccepted = 0.95
    static let gatePreserved = 1.0
    static let tierOne = ["de", "es", "fr", "it", "pt", "nl", "pl", "ru"]

    struct Sample: Codable, Equatable {
        var id: String
        var language: String
        var words: Int
        var outcome: String
        var rejection: String?
        var preserved: Bool
        var changed: Bool
        var retention: Double
        var milliseconds: Int
        var proposed: String?
        var delivered: String
    }

    struct Row: Codable, Equatable {
        var language: String
        var total: Int
        var accepted: Int
        var preserved: Int
        var changed: Int
        var retention: Double
        var p50MsPerWord: Double
        var p95MsPerWord: Double

        var acceptedRate: Double { total == 0 ? 0 : Double(accepted) / Double(total) }
        var preservedRate: Double { total == 0 ? 0 : Double(preserved) / Double(total) }
        var passesGate: Bool { acceptedRate >= LanguageCleanupBench.gateAccepted && preservedRate >= LanguageCleanupBench.gatePreserved }
    }

    /// Share of the input's content words (over two letters) the text still has.
    static func retention(input: String, output: String) -> Double {
        let words = Set(TextMetrics.normalizedWords(input).filter { $0.count > 2 })
        guard !words.isEmpty else { return 1 }
        let kept = Set(TextMetrics.normalizedWords(output))
        return Double(words.filter { kept.contains($0) }.count) / Double(words.count)
    }

    /// Whether `text` reads as `language` rather than English. Text under three words can't be told apart and counts as preserved.
    static func preserved(_ text: String, language: DictationLanguage, detector: any LanguageDetector) -> Bool {
        guard language != .english, TextMetrics.wordCount(text) >= LanguageResolver.defaultMinimumWords else { return true }
        return detector.hypotheses(for: text, among: [language, .english]).first?.language == language
    }

    static func rows(_ samples: [Sample]) -> [Row] {
        Dictionary(grouping: samples, by: \.language).map { language, items in
            let perWord = items.map { Double($0.milliseconds) / Double(max($0.words, 1)) }
            return Row(
                language: language, total: items.count, accepted: items.filter { $0.outcome == SmartOutcome.ok.rawValue }.count,
                preserved: items.filter(\.preserved).count, changed: items.filter(\.changed).count, retention: items.map(\.retention).reduce(0, +) / Double(items.count),
                p50MsPerWord: Stats.median(perWord), p95MsPerWord: Stats.percentile(perWord, 95))
        }.sorted { $0.language < $1.language }
    }

    static func report(_ rows: [Row], samples: [Sample], model: String) -> String {
        var lines = [
            "# Thorough cleanup by language", "", "Model: \(model). Level: Thorough. Fixtures: Tests/Fixtures/multilingual.", "",
            "| language | n | accepted | language-preserved | edited by the model | content-word retention | p50 ms/word | p95 ms/word | gate |",
            "| --- | --- | --- | --- | --- | --- | --- | --- | --- |",
        ]
        let english = rows.first { $0.language == "en" }
        for row in rows {
            let gate = tierOne.contains(row.language) ? (row.passesGate ? "pass" : "FAIL") : "n/a"
            lines.append(
                "| \(row.language) | \(row.total) | \(Int((row.acceptedRate * 100).rounded())) percent | \(Int((row.preservedRate * 100).rounded())) percent | \(row.changed) of \(row.total) | \(Int((row.retention * 100).rounded())) percent | \(String(format: "%.0f", row.p50MsPerWord)) | \(String(format: "%.0f", row.p95MsPerWord)) | \(gate) |"
            )
        }
        if let english, english.p50MsPerWord > 0 {
            lines += ["", "Median latency per word against English:", ""]
            for row in rows where row.language != "en" {
                lines.append("- \(row.language): \(String(format: "%.2f", row.p50MsPerWord / english.p50MsPerWord))x")
            }
        }
        let failures = samples.filter { $0.outcome != SmartOutcome.ok.rawValue || !$0.preserved }
        if !failures.isEmpty {
            lines += ["", "## Not accepted or not language-preserved", ""]
            for item in failures {
                lines.append("- \(item.id): \(item.outcome)\(item.rejection.map { " (\($0))" } ?? "")\(item.preserved ? "" : ", language changed")")
            }
        }
        let tier = rows.filter { tierOne.contains($0.language) }
        lines += ["", tier.allSatisfy(\.passesGate) ? "Ship gate: PASS." : "Ship gate: FAIL. Thorough stays English only outside the passing languages."]
        return lines.joined(separator: "\n")
    }
}

/// `mouthtype-bench language-cleanup`: runs every multilingual fixture through the app's order (the deterministic pipeline for
/// its language, then Thorough) and reports per language the share the guard accepted, the share that stayed in the language,
/// content-word retention and latency per word. A measured run with the local model, not part of CI.
struct LanguageCleanupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "language-cleanup",
        abstract: "Measure Thorough cleanup per language on the multilingual fixtures and check the ship gate."
    )

    @Option(help: "Directory of <code>.json fixtures.") var fixtures: String = MultilingualFixtures.defaultDirectory
    @Option(help: "Local MLX cleaner to evaluate. Default: the Thorough model.") var cleaner: String = CleanerCatalog.smartCleanupID
    @Option(help: "Only these language codes, comma separated. Default: every fixture language.") var languages: String?
    @Option(help: "Give up on a take after this many milliseconds. Default: the app's word-based budget.") var timeoutMs: Int?
    @Option(help: "Write the Markdown report to this path.") var report: String?
    @Option(help: "Write the per-take samples as JSON to this path.") var out: String?

    func run() async throws {
        guard let spec = CleanerCatalog.mlxSpec(id: cleaner), let model = try CleanerCatalog.make(id: cleaner) as? MLXCleaner else {
            throw ValidationError("--cleaner must name a local MLX cleaner.")
        }
        guard model.isDownloaded else { throw ValidationError("\(spec.displayName) is not on disk.") }
        try await model.load()
        _ = try? await model.clean("warm up the model before timing it", context: CleanupContext())
        let observed = ObservedCleaner(model)
        let detector = BenchLanguageDetector()
        let budget: (@Sendable (Int) -> Duration)? = timeoutMs.map { ms in { @Sendable _ in Duration.milliseconds(ms) } }
        let smart = SmartCleanup(
            cleaner: observed, budget: budget, languageDetector: detector, thoroughLanguages: Set(DictationLanguage.allCases))

        let loaded = try MultilingualFixtures.load(directory: URL(fileURLWithPath: fixtures))
        let wanted = languages.map { Set($0.split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }) }
        var samples: [LanguageCleanupBench.Sample] = []
        for code in loaded.keys.sorted() where wanted?.contains(code) ?? true {
            guard let language = DictationLanguage(code: code) else { continue }
            for entry in loaded[code] ?? [] {
                await observed.reset()
                let context: InsertionContext? = entry.id.contains("blend") ? InsertionContext(before: "Wir haben einen ") : nil
                let run = await SmartRunner.run(entry.raw, level: .medium, smart: smart, context: context, language: language)
                guard run.result.outcome != SmartOutcome.skipped || run.result.rejection != nil else { continue }
                let proposed = await observed.proposed
                let judged = proposed ?? run.result.text
                let sample = LanguageCleanupBench.Sample(
                    id: entry.id, language: code, words: TextMetrics.wordCount(run.deterministic), outcome: run.result.outcome.rawValue,
                    rejection: run.result.rejection,
                    preserved: LanguageCleanupBench.preserved(judged, language: language, detector: detector),
                    changed: judged != run.deterministic,
                    retention: LanguageCleanupBench.retention(input: run.deterministic, output: judged),
                    milliseconds: run.result.milliseconds, proposed: proposed, delivered: run.result.text)
                samples.append(sample)
                print("\(code)\t\(entry.id)\t\(sample.outcome)\tpreserved=\(sample.preserved)\t\(sample.milliseconds) ms")
            }
        }
        let rows = LanguageCleanupBench.rows(samples)
        let text = LanguageCleanupBench.report(rows, samples: samples, model: spec.displayName)
        print("\n" + text)
        if let report { try text.write(toFile: report, atomically: true, encoding: .utf8) }
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(samples).write(to: URL(fileURLWithPath: out))
        }
        if !rows.filter({ LanguageCleanupBench.tierOne.contains($0.language) }).allSatisfy(\.passesGate) { throw ExitCode.failure }
    }
}
