import Foundation
import Testing
@testable import mouthtype_bench

@Suite struct MultilingualFixturesTests {
    private static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let directory = root.appendingPathComponent(MultilingualFixtures.defaultDirectory)

    private func load() throws -> [String: [MultilingualEntry]] {
        try MultilingualFixtures.load(directory: Self.directory)
    }

    @Test func coversTheDesignLanguages() throws {
        let languages = Set(try load().keys)
        #expect(languages.isSuperset(of: ["en", "de", "es", "fr", "it", "pt", "nl", "pl", "ru", "uk"]))
    }

    @Test func entriesMatchTheirFileAndHaveUniqueIds() throws {
        let loaded = try load()
        var seen = Set<String>()
        for (code, entries) in loaded {
            for entry in entries {
                #expect(entry.language == code, "\(entry.id) is in \(code).json")
                #expect(entry.id.hasPrefix("\(code)-"), "\(entry.id)")
                #expect(!entry.raw.isEmpty && !entry.notes.isEmpty, "\(entry.id)")
                #expect(seen.insert(entry.id).inserted, "duplicate id \(entry.id)")
            }
        }
    }

    @Test func damageTableCollisionStringsAreVerbatim() throws {
        let loaded = try load()
        let collisions: [(String, String)] = [
            ("de", "Er kommt um drei."),
            ("de", "Ich glaube, dass das das Beste ist."),
            ("de", "Hund gekauft"),
            ("pt", "Um dia eu vou embora."),
            ("da", "Han er her."),
            ("nl", "Ten eerste is het te duur."),
            ("pl", "Ten dom jest duży."),
            ("it", "Vedi l'articolo 5 comma 2."),
        ]
        for (code, raw) in collisions {
            #expect(loaded[code]?.contains { $0.raw == raw } == true, "\(code) is missing \(raw)")
        }
    }

    @Test func everyLengthBucketHasTakesInEveryDetectionLanguage() throws {
        let loaded = try load()
        for code in LanguageDetectionBench.tierOne {
            for words in LanguageDetectionBench.buckets {
                #expect(!LanguageDetectionBench.samples(loaded[code] ?? [], words: words).isEmpty, "\(code) has no \(words)-word take")
            }
        }
    }
}

@Suite struct LanguageDetectionBenchTests {
    @Test func samplesAreWordPrefixesOfLongEnoughEntries() {
        let entries = [
            MultilingualEntry(id: "a", language: "en", raw: "one two three four five", notes: "n"),
            MultilingualEntry(id: "b", language: "en", raw: "one two", notes: "n"),
        ]
        #expect(LanguageDetectionBench.samples(entries, words: 3) == ["one two three"])
        #expect(LanguageDetectionBench.samples(entries, words: 2) == ["one two", "one two"])
        #expect(LanguageDetectionBench.samples(entries, words: 6).isEmpty)
    }

    @Test func singleCandidateAndShortTakesFallBack() {
        let german = "Können wir das Treffen auf Donnerstag verschieben"
        #expect(LanguageDetectionBench.detect(german, candidates: ["en"], confidence: 0.5, minimumWords: 3) == .fallback)
        #expect(LanguageDetectionBench.detect("Guten Morgen", candidates: ["en", "de"], confidence: 0.5, minimumWords: 3) == .fallback)
    }

    @Test func impossibleConfidenceFallsBack() {
        let german = "Können wir das Treffen auf Donnerstag verschieben"
        #expect(LanguageDetectionBench.detect(german, candidates: ["en", "de"], confidence: 1.01, minimumWords: 3) == .fallback)
    }

    @Test func detectsAClearSentenceAmongCandidates() {
        let german = "Können wir das Treffen auf Donnerstag verschieben, weil der Kunde erst um elf Uhr ankommt?"
        #expect(LanguageDetectionBench.detect(german, candidates: ["en", "de"], confidence: 0.5, minimumWords: 3) == .detected("de"))
    }

    @Test func fallbackCountsAsCorrectOnlyForTheFirstCandidate() {
        var cell = LanguageDetectionBench.Cell()
        cell.record(.fallback, expected: "en", firstCandidate: "en")
        cell.record(.fallback, expected: "de", firstCandidate: "en")
        cell.record(.detected("de"), expected: "de", firstCandidate: "en")
        cell.record(.detected("en"), expected: "de", firstCandidate: "en")
        #expect(cell.total == 4 && cell.correct == 2 && cell.wrong == 2 && cell.fallbacks == 2)
    }

    @Test func candidateSetsPairEnglishWithTheLanguage() {
        #expect(LanguageDetectionBench.candidateSets(for: "de", all: ["de", "en", "fr"], includeAll: false) == [["en", "de"]])
        #expect(LanguageDetectionBench.candidateSets(for: "en", all: ["de", "en"], includeAll: false).isEmpty)
        #expect(LanguageDetectionBench.candidateSets(for: "fr", all: ["fr", "de", "en"], includeAll: true) == [["en", "fr"], ["en", "de", "fr"]])
    }
}

@Suite struct CleanupCaseLanguageTests {
    @Test func languageIsOptionalAndDecodes() throws {
        let plain = Data(#"{"id":"a","category":"filler","input":"x","vocabulary":[],"mustContain":[],"mustNotContain":[],"reference":"x"}"#.utf8)
        #expect(try CleanupFixtures.decode(Data("[".utf8) + plain + Data("]".utf8)).first?.language == nil)
        let german = Data(#"{"id":"a","category":"filler","input":"x","vocabulary":[],"mustContain":[],"mustNotContain":[],"reference":"x","language":"de"}"#.utf8)
        #expect(try CleanupFixtures.decode(Data("[".utf8) + german + Data("]".utf8)).first?.language == "de")
        let smart = Data(#"{"id":"a","input":"x","target":"x","language":"de"}"#.utf8)
        #expect(try JSONDecoder().decode(SmartCase.self, from: smart).language == "de")
    }
}
