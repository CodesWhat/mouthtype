import Foundation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct StatsModelTests {
    private let base = Date()

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-stats-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    @discardableResult
    private func dictate(_ store: TranscriptStore, minutes: Double, text: String, secure: Bool = false) throws -> String {
        let id = try store.begin(DictationStart(
            startedAt: base.addingTimeInterval(-minutes * 60), target: DictationTarget(isSecure: secure ? true : nil)))
        try store.recordInsertion(id, InsertionRecord(finalText: text))
        return id
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func secureTakesAreExcludedFromEveryNumber() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two three")
        try dictate(store, minutes: 2, text: "a very long secret passphrase that must never be counted anywhere", secure: true)
        let model = StatsModel(store: store, observing: false)
        await model.load()
        let snapshot = try #require(model.snapshot)
        #expect(snapshot.report.wordsAllTime == 3)
        #expect(snapshot.report.dictationCount == 1)
        #expect(snapshot.records.longestDictation?.value.words == 3)
        #expect(snapshot.records.biggestDay?.value == 3)
    }

    @Test func noHistoryHasNoSnapshotData() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let model = StatsModel(store: store, observing: false)
        await model.load()
        #expect(model.snapshot?.hasHistory == false)
        #expect(model.snapshot?.daily.isEmpty == true)
        let missing = StatsModel(store: nil, observing: false)
        await missing.load()
        #expect(missing.snapshot == nil && missing.error == "Stats are unavailable.")
    }

    @Test func finishedTakesUpdateWhileActive() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let model = StatsModel(store: store)
        await waitUntil { model.snapshot?.report.wordsAllTime == 2 }
        #expect(model.snapshot?.report.wordsAllTime == 2)
        try dictate(store, minutes: 2, text: "three four five")
        await waitUntil { model.snapshot?.report.wordsAllTime == 5 }
        #expect(model.snapshot?.report.wordsAllTime == 5)
        #expect(model.snapshot?.daily.count == StatsSnapshot.dailyWindowDays)
    }

    @Test func deactivatedModelStopsObservingAndDropsALateRead() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let model = StatsModel(store: store, observing: false)
        model.fetch = { store, now in
            Thread.sleep(forTimeInterval: 0.3)
            return try store.statsSnapshot(now: now)
        }
        model.activate()
        model.startReload()
        model.deactivate()
        try await Task.sleep(for: .milliseconds(600))
        #expect(model.snapshot == nil)
        try dictate(store, minutes: 2, text: "three")
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.snapshot == nil)
    }
}
