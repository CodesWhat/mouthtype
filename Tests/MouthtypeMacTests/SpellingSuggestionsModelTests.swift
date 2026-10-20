import Foundation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SpellingSuggestionsModelTests {
    private let base = Date(timeIntervalSince1970: 1_791_806_400)

    private struct Fixture {
        var dir: URL
        var store: TranscriptStore
        var vocabulary: FileVocabulary
        var dismissedURL: URL
    }

    private func fixture(rules: [(String, String)] = [("shivon", "Siobhan"), ("win", "Nguyen")]) throws -> Fixture {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-suggest-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let vocabulary = FileVocabulary(url: dir.appendingPathComponent("dictionary.json"))
        for (heard, written) in rules { try vocabulary.save(heard: heard, written: written) }
        return Fixture(dir: dir, store: try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")),
                       vocabulary: vocabulary, dismissedURL: dir.appendingPathComponent("dismissed-suggestions.json"))
    }

    private func dictate(_ store: TranscriptStore, _ n: Int, raw: String, final: String? = nil, secure: Bool = false) throws {
        let id = try store.begin(DictationStart(startedAt: base.addingTimeInterval(Double(n) * 60),
            target: DictationTarget(appName: "Notes", isSecure: secure ? true : nil)))
        try store.recordTranscription(id, TranscriptionRecord(
            transcription: Transcription(text: raw, words: [], confidence: 0.9, processingSeconds: 0.1, engineID: "test", modelRevision: "1"),
            rawText: raw, boostTerms: ["Siobhan"]))
        try store.recordInsertion(id, InsertionRecord(finalText: final ?? raw))
    }

    private func seed(_ store: TranscriptStore, shabanTakes: Int = 2) throws {
        for n in 0..<shabanTakes { try dictate(store, n, raw: "Shaban took a minute \(n)") }
        try dictate(store, 50, raw: "i hope we win the contract")
        for n in 60..<64 { try dictate(store, n, raw: "we shipped build \(n) after lunch") }
    }

    private func model(_ f: Fixture) -> SpellingSuggestionsModel {
        SpellingSuggestionsModel(vocabulary: f.vocabulary, store: f.store, dismissedURL: f.dismissedURL)
    }

    @Test func loadsSuggestionsAndHazardsFromRecentTakes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        await model.reload()
        let heard = try #require(model.suggestions.first { $0.kind == .misheardVariant && $0.written == "Siobhan" })
        #expect(heard.heardForms == ["shaban"])
        #expect(model.suggestions.contains { $0.kind == .removeHazard && $0.heardForms == ["win"] })
        #expect(SpellingSuggestionRow.title(heard) == "shaban → Siobhan")
        let hazard = try #require(model.suggestions.first { $0.kind == .removeHazard })
        #expect(SpellingSuggestionRow.title(hazard) == "Remove ‘win’ → Nguyen")
    }

    @Test func emptyStateWhenThereIsNothingToSuggest() async throws {
        let f = try fixture(rules: [])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for n in 0..<5 { try dictate(f.store, n, raw: "we shipped build \(n) after lunch") }
        let withTakes = model(f)
        await withTakes.reload()
        #expect(withTakes.suggestions.isEmpty)
        let noStore = SpellingSuggestionsModel(vocabulary: f.vocabulary, store: nil, dismissedURL: f.dismissedURL)
        await noStore.reload()
        #expect(noStore.suggestions.isEmpty)
    }

    @Test func secureTakesAreNeverRead() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for n in 0..<4 { try dictate(f.store, n, raw: "Shaban \(n) typed a password", secure: true) }
        let model = model(f)
        await model.reload()
        #expect(!model.suggestions.contains { $0.kind == .misheardVariant })
    }

    @Test func everydayWordsAreNeverOfferedAsHeardForms() async throws {
        let f = try fixture(rules: [("will", "Will"), ("shivon", "Siobhan")])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for n in 0..<4 { try dictate(f.store, n, raw: "we will see about this \(n)"); try dictate(f.store, n + 10, raw: "the sea son changed \(n)") }
        let model = model(f)
        await model.reload()
        for s in model.suggestions where s.kind != .removeHazard {
            for form in s.heardForms { #expect(!OrdinaryWords.isOrdinary(form) || form.contains(" "), "\(form)") }
        }
    }

    @Test func addSavesThroughTheEditorPathAndUndoPutsItBack() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        var changed = 0
        model.onRulesChanged = { changed += 1 }
        await model.reload()
        let suggestion = try #require(model.suggestions.first { $0.written == "Siobhan" && $0.kind == .misheardVariant })
        model.add(suggestion)
        #expect(try f.vocabulary.allRules().contains(DictionaryRule(heard: "shaban", written: "Siobhan")))
        #expect(model.undo?.message == "Added Siobhan.")
        #expect(!model.suggestions.contains { $0.id == suggestion.id })
        #expect(changed == 1)
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.heard) == ["shivon", "win"])
        #expect(model.undo == nil)
    }

    @Test func addFailureRollsBackAndReportsTheError() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let model = model(f)
        let clash = SpellingSuggestion(written: "Siobhan", heardForms: ["fresh", "Win"], kind: .misheardVariant,
                                       evidence: [], count: 3, confidence: 0.8)
        model.add(clash)
        #expect(model.error != nil)
        #expect(try f.vocabulary.allRules().map(\.heard) == ["shivon", "win"])
        #expect(model.undo == nil)
    }

    @Test func removeDeletesTheHazardRuleAndUndoRestoresIt() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        await model.reload()
        let hazard = try #require(model.suggestions.first { $0.kind == .removeHazard && $0.heardForms == ["win"] })
        model.remove(hazard)
        #expect(try f.vocabulary.allRules().map(\.heard) == ["shivon"])
        model.undoLast()
        #expect(try f.vocabulary.allRules().contains(DictionaryRule(heard: "win", written: "Nguyen")))
    }

    @Test func dismissIsRememberedAndOnlyResurfacesWhenTheCountDoubles() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store, shabanTakes: 2)
        let first = model(f)
        await first.reload()
        let suggestion = try #require(first.suggestions.first { $0.written == "Siobhan" && $0.kind == .misheardVariant })
        #expect(suggestion.count == 2)
        first.dismiss(suggestion)
        #expect(!first.suggestions.contains { $0.id == suggestion.id })

        let reopened = model(f)
        await reopened.reload()
        #expect(!reopened.suggestions.contains { $0.id == suggestion.id })
        let saved = try JSONDecoder().decode(DismissedSuggestions.self, from: Data(contentsOf: f.dismissedURL))
        #expect(saved.version == DismissedSuggestions.currentVersion && saved.counts[suggestion.id] == 2)

        try dictate(f.store, 20, raw: "Shaban called back")
        await reopened.reload()
        #expect(!reopened.suggestions.contains { $0.id == suggestion.id })
        try dictate(f.store, 21, raw: "Shaban again")
        await reopened.reload()
        #expect(reopened.suggestions.contains { $0.id == suggestion.id })
    }

    @Test func aReloadThatFinishesAfterDeactivateIsDropped() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        model.fetchRecent = { store, limit in
            let rows = try store.recentTakes(limit: limit)
            Thread.sleep(forTimeInterval: 0.4)
            return rows
        }
        model.activate()
        try await Task.sleep(for: .milliseconds(100))
        model.deactivate()
        try await Task.sleep(for: .milliseconds(700))
        #expect(model.suggestions.isEmpty)
        model.fetchRecent = { store, limit in try store.recentTakes(limit: limit) }
        model.activate()
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.suggestions.isEmpty)
    }

    @Test func aNewerReloadWinsOverAnOlderSlowOne() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let calls = Calls()
        model.fetchRecent = { store, limit in
            let first = calls.next()
            let rows = try store.recentTakes(limit: limit)
            if first { Thread.sleep(forTimeInterval: 0.4); return [] }
            return rows
        }
        model.activate()
        try await Task.sleep(for: .milliseconds(100))
        await model.reload()
        try await Task.sleep(for: .milliseconds(700))
        #expect(!model.suggestions.isEmpty)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count == 1 }
}
