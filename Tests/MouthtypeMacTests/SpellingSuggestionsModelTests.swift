import Foundation
import os
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
        return Fixture(
            dir: dir, store: try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")),
            vocabulary: vocabulary, dismissedURL: dir.appendingPathComponent("dismissed-suggestions.json"))
    }

    private func dictate(_ store: TranscriptStore, _ n: Int, raw: String, final: String? = nil, secure: Bool = false) throws {
        let id = try store.begin(
            DictationStart(
                startedAt: base.addingTimeInterval(Double(n) * 60),
                target: DictationTarget(appName: "Notes", isSecure: secure ? true : nil)))
        try store.recordTranscription(
            id,
            TranscriptionRecord(
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
        let model = SpellingSuggestionsModel(vocabulary: f.vocabulary, store: f.store, dismissedURL: f.dismissedURL)
        model.isKnownWord = { _ in false }
        return model
    }

    @Test func systemWordCheckerSmokeTest() {
        let checker = SystemWordChecker()
        #expect(checker.isKnown("candy"))
        #expect(!checker.isKnown("xqzvbr"))
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

    @Test func hazardTitleNamesEveryRuleRemoveDeletes() {
        func hazard(_ rules: [DictionaryRule]) -> SpellingSuggestion {
            SpellingSuggestion(
                written: "Nguyen", heardForms: rules.map(\.heard), kind: .removeHazard, evidence: [], count: 0, confidence: 0.3,
                hazardRules: rules)
        }
        let will = DictionaryRule(heard: "will", written: "Nguyen")
        let win = DictionaryRule(heard: "win", written: "NGUYEN")
        let wynn = DictionaryRule(heard: "wynn", written: "nguyen")
        #expect(SpellingSuggestionRow.title(hazard([will])) == "Remove ‘will’ → Nguyen")
        #expect(SpellingSuggestionRow.title(hazard([will, win])) == "Remove ‘will’ → Nguyen and ‘win’ → NGUYEN")
        #expect(SpellingSuggestionRow.title(hazard([will, win, wynn])) == "Remove ‘will’ → Nguyen, ‘win’ → NGUYEN, and ‘wynn’ → nguyen")
    }

    @Test func emptyStateWhenThereIsNothingToSuggest() async throws {
        let f = try fixture(rules: [])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for n in 0..<5 { try dictate(f.store, n, raw: "we shipped build \(n) after lunch") }
        let withTakes = model(f)
        await withTakes.reload()
        #expect(withTakes.suggestions.isEmpty)
        let noStore = SpellingSuggestionsModel(vocabulary: f.vocabulary, store: nil, dismissedURL: f.dismissedURL)
        noStore.isKnownWord = { _ in false }
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
        let clash = SpellingSuggestion(
            written: "Siobhan", heardForms: ["fresh", "Win"], kind: .misheardVariant,
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

    @Test func aReloadWithUnchangedTakesAndRulesReusesTheLastResult() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let probe = CheckProbe()
        model.isKnownWord = { _ in
            probe.hit(); return false
        }
        await model.reload()
        let first = model.suggestions
        let after = probe.count
        #expect(!first.isEmpty && after > 0)
        await model.reload()
        #expect(probe.count == after)
        #expect(model.suggestions == first)
        // A new take, or a rule edit, recomputes.
        try dictate(f.store, 70, raw: "another take entirely")
        await model.reload()
        #expect(probe.count > after)
        let beforeRule = model.suggestions
        #expect(beforeRule.contains { $0.kind == .misheardVariant })
        try f.vocabulary.save(heard: "shaban", written: "Siobhan")
        await model.reload()
        #expect(!model.suggestions.contains { $0.kind == .misheardVariant })
    }

    @Test func aReloadAfterATakeEditOrDeleteRecomputes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let probe = CheckProbe()
        model.isKnownWord = { _ in
            probe.hit(); return false
        }
        await model.reload()
        let first = model.suggestions
        var count = probe.count
        #expect(first.contains { $0.kind == .misheardVariant })
        // Same take count and latest start, but a take's final text changed.
        let edited = try f.store.recentTakes(limit: 100).first { $0.rawText == "Shaban took a minute 0" }
        try f.store.recordInsertion(try #require(edited).id, InsertionRecord(finalText: "Siobhan took a minute 0"))
        await model.reload()
        #expect(probe.count > count)
        count = probe.count
        // Deleting an older take keeps the latest start, and the count when a newer one replaces it in the window.
        let doomed = try f.store.recentTakes(limit: 100).first { $0.rawText == "Shaban took a minute 1" }
        try f.store.delete(try #require(doomed).id)
        await model.reload()
        #expect(probe.count > count)
    }

    @Test func aReloadThatFinishesAfterDeactivateIsDropped() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = DispatchSemaphore(value: 0)
        let finished = OSAllocatedUnfairLock(initialState: false)
        model.fetchRecent = { store, limit in
            let rows = try store.recentTakes(limit: limit)
            started.withLock { $0 = true }
            // Held until after deactivate; the cap only bounds a hang.
            _ = release.wait(timeout: .now() + 60)
            finished.withLock { $0 = true }
            return rows
        }
        model.activate()
        // Deactivate only once the fetch is really in flight.
        for _ in 0..<1000 where !started.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        model.deactivate()
        release.signal()
        for _ in 0..<1000 where !finished.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(10)) }
        // Let the finished fetch's result reach the model, which must drop it.
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.suggestions.isEmpty)
        model.fetchRecent = { store, limit in try store.recentTakes(limit: limit) }
        model.activate()
        for _ in 0..<1000 where model.suggestions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
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

    @Test func removeRefusesARuleTheUserChangedAndRefreshes() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        await model.reload()
        let hazard = try #require(model.suggestions.first { $0.kind == .removeHazard && $0.heardForms == ["win"] })
        try f.vocabulary.save(original: DictionaryRule(heard: "win", written: "Nguyen"), rule: DictionaryRule(heard: "win", written: "Winn"))
        model.remove(hazard)
        #expect(model.error == "That spelling changed. Refreshing suggestions.")
        #expect(try f.vocabulary.allRules().contains(DictionaryRule(heard: "win", written: "Winn")))
        #expect(model.undo == nil)
    }

    @Test func undoRestoresTheOriginalEntryExactly() async throws {
        let f = try fixture(rules: [])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let long = String(repeating: "y", count: 200)
        try """
        [{"heard":"win","written":"Nguyen","extra":7},{"heard":"mid","written":"\(long)"},{"heard":"last","written":"Last"}]
        """.write(to: f.vocabulary.url, atomically: true, encoding: .utf8)
        let model = model(f)
        let hazard = SpellingSuggestion(
            written: "Nguyen", heardForms: ["win"], kind: .removeHazard, evidence: [], count: 0, confidence: 0.3,
            hazardRules: [DictionaryRule(heard: "win", written: "Nguyen")])
        model.remove(hazard)
        #expect(try f.vocabulary.allRules().map(\.heard) == ["mid", "last"])
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.heard) == ["win", "mid", "last"])
        let entries = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: f.vocabulary.url)) as? [[String: Any]])
        #expect(entries[0]["extra"] as? Int == 7)

        let longHazard = SpellingSuggestion(
            written: long, heardForms: ["mid"], kind: .removeHazard, evidence: [], count: 0, confidence: 0.3,
            hazardRules: [DictionaryRule(heard: "mid", written: long)])
        model.remove(longHazard)
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.written) == ["Nguyen", long, "Last"])
    }

    @Test func undoOfAddLeavesAChangedRuleAlone() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let model = model(f)
        let suggestion = SpellingSuggestion(written: "Siobhan", heardForms: ["shaban"], kind: .misheardVariant, evidence: [], count: 3, confidence: 0.8)
        model.add(suggestion)
        try f.vocabulary.save(original: DictionaryRule(heard: "shaban", written: "Siobhan"), rule: DictionaryRule(heard: "shaban", written: "Shavon"))
        model.undoLast()
        #expect(model.error != nil)
        #expect(model.undo == nil)
        #expect(try f.vocabulary.allRules().contains(DictionaryRule(heard: "shaban", written: "Shavon")))
    }

    @Test func undoOfRemoveIsRefusedAfterAnotherLibraryChange() async throws {
        let f = try fixture(rules: [("a", "Aa"), ("b", "Bb"), ("c", "Cc")])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let model = model(f)
        let hazard = SpellingSuggestion(
            written: "Bb", heardForms: ["b"], kind: .removeHazard, evidence: [], count: 0, confidence: 0.3,
            hazardRules: [DictionaryRule(heard: "b", written: "Bb")])
        // Plain remove then undo restores at the original index.
        model.remove(hazard)
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.heard) == ["a", "b", "c"])

        // The editor deleting A clears the pending Undo.
        model.remove(hazard)
        try f.vocabulary.remove(DictionaryRule(heard: "a", written: "Aa"))
        model.libraryChanged()
        #expect(model.undo == nil)
        #expect(try f.vocabulary.allRules().map(\.heard) == ["c"])

        // A change the model never heard about is still refused at restore time.
        let entries = try f.vocabulary.removeAll([DictionaryRule(heard: "c", written: "Cc")])
        try f.vocabulary.save(heard: "z", written: "Zz")
        #expect(throws: FileVocabulary.WriteError.staleUndo) { try f.vocabulary.restore(entries) }
        #expect(FileVocabulary.WriteError.staleUndo.errorDescription == "Your saved spellings changed, so this can't be undone.")
    }

    @Test func staleUndoShowsTheInlineMessage() async throws {
        let f = try fixture(rules: [("a", "Aa"), ("b", "Bb")])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let model = model(f)
        model.remove(
            SpellingSuggestion(
                written: "Bb", heardForms: ["b"], kind: .removeHazard, evidence: [], count: 0, confidence: 0.3,
                hazardRules: [DictionaryRule(heard: "b", written: "Bb")]))
        try f.vocabulary.remove(DictionaryRule(heard: "a", written: "Aa"))
        model.undoLast()
        #expect(model.error == "Your saved spellings changed, so this can't be undone.")
        #expect(model.undo == nil)
        #expect(try f.vocabulary.allRules().isEmpty)
    }

    @Test func hazardGroupKeepsEachExactRuleAndRemovesIt() async throws {
        let f = try fixture(rules: [("will", "Nguyen"), ("win", "NGUYEN")])
        defer { try? FileManager.default.removeItem(at: f.dir) }
        for n in 0..<120 { try dictate(f.store, n, raw: "we win take \(n) will go") }
        let model = model(f)
        await model.reload()
        let hazards = model.suggestions.filter { $0.kind == .removeHazard }
        let group = try #require(hazards.first { Set($0.hazardRules.map(\.heard)) == ["will", "win"] })
        #expect(Set(group.hazardRules) == [DictionaryRule(heard: "will", written: "Nguyen"), DictionaryRule(heard: "win", written: "NGUYEN")])
        // Remove just the NGUYEN one exactly.
        let single = SpellingSuggestion(
            written: "NGUYEN", heardForms: ["win"], kind: .removeHazard, evidence: [], count: 5, confidence: 0.9,
            hazardRules: [DictionaryRule(heard: "win", written: "NGUYEN")])
        model.remove(single)
        #expect(model.error == nil)
        #expect(try f.vocabulary.allRules() == [DictionaryRule(heard: "will", written: "Nguyen")])
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.heard) == ["will", "win"])
        // Removing the whole group takes both in one go, and Undo puts both back.
        model.remove(group)
        #expect(try f.vocabulary.allRules().isEmpty)
        model.undoLast()
        #expect(try f.vocabulary.allRules().map(\.heard) == ["will", "win"])
    }

    @Test func undoOfAddWithOneChangedRuleRemovesNothing() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        let model = model(f)
        model.add(SpellingSuggestion(written: "Siobhan", heardForms: ["shaban", "shavon"], kind: .misheardVariant, evidence: [], count: 3, confidence: 0.8))
        try f.vocabulary.save(original: DictionaryRule(heard: "shavon", written: "Siobhan"), rule: DictionaryRule(heard: "shavon", written: "Shavon"))
        model.undoLast()
        #expect(model.error != nil)
        #expect(model.undo == nil)
        let heard = try f.vocabulary.allRules().map(\.heard)
        #expect(heard.contains("shaban") && heard.contains("shavon"))
    }

    @Test func corruptDismissalCountsAreDroppedAndNeverOverflow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-dismiss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("dismissed-suggestions.json")
        try #"{"version":1,"counts":{"a":9223372036854775807,"b":-4,"c":5,"d":1000001}}"#.write(to: url, atomically: true, encoding: .utf8)
        let loaded = DismissedSuggestions.load(from: url)
        #expect(loaded.counts == ["c": 5])
        let probe = SpellingSuggestion(written: "x", heardForms: [], kind: .casing, evidence: [], count: 5, confidence: 0.9)
        let huge = DismissedSuggestions(counts: [probe.id: Int.max])
        #expect(huge.hides(probe))
    }

    @Test func deactivateCancelsTheRunningComputation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let probe = CancelProbe()
        model.fetchRecent = { _, _ in
            probe.started()
            for _ in 0..<500 where !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
            probe.finished(cancelled: Task.isCancelled)
            return []
        }
        model.activate()
        for _ in 0..<3000 where !probe.didStart { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.didStart)
        model.deactivate()
        for _ in 0..<3000 where probe.cancelled == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.cancelled == true)
    }

    @Test func reopeningCancelsThePreviousComputation() async throws {
        let f = try fixture()
        defer { try? FileManager.default.removeItem(at: f.dir) }
        try seed(f.store)
        let model = model(f)
        let probe = CancelProbe()
        let calls = Calls()
        model.fetchRecent = { store, limit in
            if calls.next() {
                probe.started()
                for _ in 0..<500 where !Task.isCancelled { Thread.sleep(forTimeInterval: 0.01) }
                probe.finished(cancelled: Task.isCancelled)
                return []
            }
            return try store.recentTakes(limit: limit)
        }
        model.activate()
        for _ in 0..<3000 where !probe.didStart { try await Task.sleep(for: .milliseconds(20)) }
        await model.reload()
        for _ in 0..<3000 where probe.cancelled == nil { try await Task.sleep(for: .milliseconds(20)) }
        #expect(probe.cancelled == true)
        #expect(!model.suggestions.isEmpty)
    }
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func next() -> Bool { lock.lock(); defer { lock.unlock() }; count += 1; return count == 1 }
}

private final class CancelProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _cancelled: Bool?
    var didStart: Bool { lock.lock(); defer { lock.unlock() }; return _started }
    var cancelled: Bool? { lock.lock(); defer { lock.unlock() }; return _cancelled }
    func started() { lock.lock(); _started = true; lock.unlock() }
    func finished(cancelled: Bool) { lock.lock(); _cancelled = cancelled; lock.unlock() }
}

private final class CheckProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var hits = 0
    func hit() { lock.lock(); hits += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return hits }
}
