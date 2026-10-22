import ArgumentParser
import Foundation
import NaturalLanguage

/// Language detection on transcript text, the way chunk D will do it: `NLLanguageRecognizer` constrained to a candidate set,
/// with a fallback to the first candidate under a minimum word count or a confidence threshold.
enum LanguageDetectionBench {
    static let buckets = [3, 6, 12, 25]
    static let defaultConfidence = 0.5
    static let defaultMinimumWords = 3
    /// The shipping gate from the design: at least this share correct at 6 words and up, for the tier-1 languages.
    static let gateAccuracy = 0.95
    static let gateFromWords = 6
    static let tierOne = ["en", "de", "es", "fr", "it", "pt", "nl", "pl", "ru"]

    enum Outcome: Equatable {
        case detected(String)
        case fallback
    }

    /// The first `words` words of each entry that has at least that many.
    static func samples(_ entries: [MultilingualEntry], words: Int) -> [String] {
        entries.filter { $0.wordCount >= words }.map { entry in
            entry.raw.split(whereSeparator: \.isWhitespace).prefix(words).joined(separator: " ")
        }
    }

    /// Detected language when it is a candidate and clears the threshold, otherwise `.fallback`.
    static func detect(_ text: String, candidates: [String], confidence: Double, minimumWords: Int) -> Outcome {
        guard candidates.count > 1, text.split(whereSeparator: \.isWhitespace).count >= minimumWords else { return .fallback }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0) }
        recognizer.processString(text)
        guard let best = recognizer.languageHypotheses(withMaximum: 1).first, best.value >= confidence else { return .fallback }
        return .detected(best.key.rawValue)
    }

    struct Cell: Codable, Equatable {
        var total = 0
        var correct = 0
        var wrong = 0
        var fallbacks = 0

        /// A fallback to the first candidate counts as correct when that candidate is the expected language.
        mutating func record(_ outcome: Outcome, expected: String, firstCandidate: String) {
            total += 1
            switch outcome {
            case let .detected(code):
                if code == expected { correct += 1 } else { wrong += 1 }
            case .fallback:
                fallbacks += 1
                if firstCandidate == expected { correct += 1 } else { wrong += 1 }
            }
        }

        var accuracy: Double { total == 0 ? 0 : Double(correct) / Double(total) }
    }

    struct Row: Codable, Equatable {
        var language: String
        var candidates: [String]
        var words: Int
        var cell: Cell
    }

    /// Candidate sets measured for a language: English plus that language (the bilingual Mac), and optionally the full set.
    static func candidateSets(for language: String, all: [String], includeAll: Bool) -> [[String]] {
        var sets: [[String]] = language == "en" ? [] : [["en", language]]
        if includeAll { sets.append(["en"] + all.filter { $0 != "en" }.sorted()) }
        return sets
    }

    static func measure(
        fixtures: [String: [MultilingualEntry]], includeAll: Bool, confidence: Double, minimumWords: Int
    ) -> [Row] {
        let all = fixtures.keys.sorted()
        var rows: [Row] = []
        for language in all {
            let entries = fixtures[language] ?? []
            for candidates in candidateSets(for: language, all: all, includeAll: includeAll) {
                for words in buckets {
                    var cell = Cell()
                    for text in samples(entries, words: words) {
                        cell.record(detect(text, candidates: candidates, confidence: confidence, minimumWords: minimumWords), expected: language, firstCandidate: candidates[0])
                    }
                    if cell.total > 0 { rows.append(Row(language: language, candidates: candidates, words: words, cell: cell)) }
                }
            }
        }
        return rows
    }

    /// Tier-1 rows at or above the gate's word count that fall under the gate, for the bilingual candidate sets.
    static func gateFailures(_ rows: [Row]) -> [Row] {
        rows.filter { $0.candidates.count == 2 && tierOne.contains($0.language) && $0.words >= gateFromWords && $0.cell.accuracy < gateAccuracy }
    }

    static func table(_ rows: [Row]) -> String {
        var lines = ["language\tcandidates\twords\tn\tcorrect%\twrong\tfallback"]
        for row in rows {
            let candidates = row.candidates.count > 3 ? "all \(row.candidates.count)" : row.candidates.joined(separator: "+")
            lines.append("\(row.language)\t\(candidates)\t\(row.words)\t\(row.cell.total)\t\(String(format: "%.0f", row.cell.accuracy * 100))\t\(row.cell.wrong)\t\(row.cell.fallbacks)")
        }
        return lines.joined(separator: "\n")
    }
}

/// `mouthtype-bench detect-language`: measures candidate-constrained language detection on the multilingual fixtures at 3, 6,
/// 12 and 25 words per take. A measured run, not part of CI. Gate for shipping Auto with more than one candidate: at least 95
/// percent correct at 6 words and up for the tier-1 languages, with short takes falling back instead of guessing wrong.
struct DetectLanguageCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "detect-language",
        abstract: "Measure candidate-constrained language detection accuracy on the multilingual fixtures."
    )

    @Option(help: "Directory of <code>.json fixtures.") var fixtures: String = MultilingualFixtures.defaultDirectory
    @Option(help: "Minimum recognizer confidence before a detection is used.") var confidence: Double = LanguageDetectionBench.defaultConfidence
    @Option(help: "Takes under this many words fall back to the first candidate.") var minimumWords: Int = LanguageDetectionBench.defaultMinimumWords
    @Flag(help: "Also measure against English plus every fixture language, not only English plus one.") var allCandidates = false
    @Option(help: "Also write the rows as JSON to this path.") var out: String?

    func run() throws {
        let loaded = try MultilingualFixtures.load(directory: URL(fileURLWithPath: fixtures))
        let rows = LanguageDetectionBench.measure(fixtures: loaded, includeAll: allCandidates, confidence: confidence, minimumWords: minimumWords)
        print(LanguageDetectionBench.table(rows))
        if let out {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(rows).write(to: URL(fileURLWithPath: out))
        }
        let failures = LanguageDetectionBench.gateFailures(rows)
        if failures.isEmpty {
            print("\nGate: every tier-1 language is at or above \(Int(LanguageDetectionBench.gateAccuracy * 100)) percent from \(LanguageDetectionBench.gateFromWords) words.")
        } else {
            print("\nGate FAILED:")
            for row in failures {
                print("  \(row.language) at \(row.words) words: \(String(format: "%.0f", row.cell.accuracy * 100)) percent of \(row.cell.total)")
            }
            throw ExitCode.failure
        }
    }
}
