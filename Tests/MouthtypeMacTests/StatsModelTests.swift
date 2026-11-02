import Foundation
import Testing
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct StatsModelTests {
    private let base = Date()

    /// A fresh suite per model, so a typing speed accepted on this Mac never changes what these tests compute. Nothing is written to it.
    private static func isolatedDefaults() -> UserDefaults {
        UserDefaults(suiteName: "StatsModelTests-\(UUID().uuidString)")!
    }

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-stats-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    @discardableResult
    private func dictate(_ store: TranscriptStore, minutes: Double, text: String, secure: Bool = false) throws -> String {
        let id = try store.begin(
            DictationStart(
                startedAt: base.addingTimeInterval(-minutes * 60), target: DictationTarget(isSecure: secure ? true : nil)))
        try store.recordInsertion(id, InsertionRecord(finalText: text))
        return id
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2400 where !condition() { try? await Task.sleep(for: .milliseconds(25)) }
    }

    @Test func secureTakesAreExcludedFromEveryNumber() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two three")
        try dictate(store, minutes: 2, text: "a very long secret passphrase that must never be counted anywhere", secure: true)
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
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
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        await model.load()
        #expect(model.snapshot?.hasHistory == false)
        #expect(model.snapshot?.daily.isEmpty == true)
        let missing = StatsModel(store: nil, observing: false, defaults: Self.isolatedDefaults())
        await missing.load()
        #expect(missing.snapshot == nil && missing.error == "Stats are unavailable.")
    }

    @Test func finishedTakesUpdateWhileActive() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let model = StatsModel(store: store, defaults: Self.isolatedDefaults())
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
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.fetch = { store, now, zone in
            Thread.sleep(forTimeInterval: 0.3)
            return try store.statsSnapshot(now: now, timeZone: zone)
        }
        model.activate()
        await waitUntil { model.snapshot != nil }
        model.deactivate()
        let late = Task { await model.load() }
        model.activate()
        model.deactivate()
        await late.value
        let before = model.snapshot
        try dictate(store, minutes: 2, text: "three")
        try await Task.sleep(for: .milliseconds(300))
        #expect(model.snapshot == before)
    }

    @Test func aSlowEarlierLoadCannotOverwriteANewerObservationResult() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        let stale = try store.statsSnapshot(now: base)
        model.fetch = { _, _, _ in
            Thread.sleep(forTimeInterval: 0.4)
            var old = stale
            old.report.wordsAllTime = 999
            return old
        }
        let slow = Task { await model.load() }
        try await Task.sleep(for: .milliseconds(50))
        model.activate()
        await waitUntil { model.snapshot?.report.wordsAllTime == 2 }
        #expect(model.snapshot?.report.wordsAllTime == 2)
        await slow.value
        #expect(model.snapshot?.report.wordsAllTime == 2)
    }

    private final class Deliveries: @unchecked Sendable {
        private let lock = NSLock()
        private var callbacks: [@Sendable (StatsSnapshot) -> Void] = []
        func add(_ callback: @escaping @Sendable (StatsSnapshot) -> Void) { lock.withLock { callbacks.append(callback) } }
        var all: [@Sendable (StatsSnapshot) -> Void] { lock.withLock { callbacks } }
    }

    @Test func aReplacedObservationsLateCallbackIsDropped() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = try store.statsSnapshot(now: base)
        try dictate(store, minutes: 1, text: "one two")
        let second = try store.statsSnapshot(now: base)
        let deliveries = Deliveries()
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.startObservation = { _, _, _, _, onChange in
            deliveries.add(onChange)
            return nil
        }
        model.activate()
        #expect(deliveries.all.count == 1)
        // A day change restarts the observation, replacing the first one while its callback is still held.
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await waitUntil { deliveries.all.count == 2 }
        let replaced = deliveries.all
        try #require(replaced.count == 2)
        replaced[1](second)
        #expect(model.snapshot?.report.wordsAllTime == 2)
        replaced[0](first)
        #expect(model.snapshot?.report.wordsAllTime == 2)
        model.deactivate()
    }

    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var date: Date
        private(set) var sleeps: [Duration] = []
        init(_ date: Date) { self.date = date }
        var current: Date { lock.withLock { date } }
        func advance(to new: Date) { lock.withLock { date = new } }
        func record(_ d: Duration) -> Int {
            lock.withLock {
                sleeps.append(d); return sleeps.count
            }
        }
    }

    @Test func numbersRollOverAtMidnightWithTheInjectedClock() async throws {
        let zone = TimeZone.current
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        let evening = try #require(calendar.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 23, minute: 59)))
        let nextMorning = evening.addingTimeInterval(120)
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = try store.begin(DictationStart(startedAt: evening.addingTimeInterval(-60)))
        try store.recordInsertion(id, InsertionRecord(finalText: "one two three"))

        let clock = Clock(evening)
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.now = { clock.current }
        model.timeZoneProvider = { zone }
        model.sleep = { duration in
            if clock.record(duration) == 1 {
                clock.advance(to: nextMorning)
            } else {
                try await Task.sleep(for: .seconds(3_600))
            }
        }
        model.activate()
        await waitUntil { model.snapshot?.daily.last?.day == "2026-03-11" }
        #expect(clock.sleeps.first == .seconds(60))
        let snapshot = try #require(model.snapshot)
        #expect(snapshot.daily.last?.day == "2026-03-11")
        #expect(snapshot.report.wordsToday == 0)
        #expect(snapshot.report.wordsThisWeek == 3)
        model.deactivate()
    }

    @Test func aDayChangeNotificationRecomputesWithTheCurrentDate() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let clock = Clock(base)
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.now = { clock.current }
        model.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        model.activate()
        await waitUntil { model.snapshot != nil }
        let today = model.snapshot?.daily.last?.day
        clock.advance(to: base.addingTimeInterval(2 * 86_400))
        NotificationCenter.default.post(name: .NSCalendarDayChanged, object: nil)
        await waitUntil { model.snapshot?.daily.last?.day != today }
        #expect(model.snapshot?.daily.last?.day != today)
        #expect(model.snapshot?.report.wordsToday == 0)
        model.deactivate()
    }

    private final class Zone: @unchecked Sendable {
        private let lock = NSLock()
        private var zone: TimeZone
        init(_ zone: TimeZone) { self.zone = zone }
        var current: TimeZone { lock.withLock { zone } }
        func set(_ new: TimeZone) { lock.withLock { zone = new } }
    }

    @Test func aTimeZoneChangeRecomputesInTheNewZone() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tokyo = try #require(TimeZone(identifier: "Asia/Tokyo"))
        let honolulu = try #require(TimeZone(identifier: "Pacific/Honolulu"))
        // 2026-03-10 20:00 UTC is Mar 11 in Tokyo and Mar 10 in Honolulu.
        let instant = Date(timeIntervalSince1970: 1_773_172_800)
        let id = try store.begin(DictationStart(startedAt: instant.addingTimeInterval(-60)))
        try store.recordInsertion(id, InsertionRecord(finalText: "one two three"))
        let zone = Zone(tokyo)
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.now = { instant }
        model.timeZoneProvider = { zone.current }
        model.sleep = { _ in try await Task.sleep(for: .seconds(3_600)) }
        model.activate()
        await waitUntil { model.snapshot?.daily.last?.day == "2026-03-11" }
        #expect(model.snapshot?.daily.last?.day == "2026-03-11")
        zone.set(honolulu)
        NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)
        await waitUntil { model.snapshot?.daily.last?.day == "2026-03-10" }
        #expect(model.snapshot?.daily.last?.day == "2026-03-10")
        model.deactivate()
    }

    @Test func aMissingStoreWhileActiveShowsTheUnavailableState() async throws {
        let model = StatsModel(store: nil, observing: false, defaults: Self.isolatedDefaults())
        model.activate()
        #expect(model.snapshot == nil && model.error == "Stats are unavailable.")
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        model.store = store
        await waitUntil { model.error == nil && model.snapshot != nil }
        #expect(model.error == nil)
        #expect(model.snapshot?.report.wordsAllTime == 2)
        model.deactivate()
    }

    @Test func anObservationErrorShowsAndASuccessfulDeliveryClearsIt() async throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try dictate(store, minutes: 1, text: "one two")
        let model = StatsModel(store: store, observing: false, defaults: Self.isolatedDefaults())
        model.activate()
        await waitUntil { model.snapshot != nil }
        model.startObservation = { _, _, _, onError, _ in
            DispatchQueue.main.async { onError(CocoaError(.fileReadUnknown)) }
            return nil
        }
        model.deactivate()
        model.activate()
        await waitUntil { model.error != nil }
        #expect(model.error != nil)
        #expect(model.snapshot == nil)
        model.startObservation = { store, zone, clock, onError, onChange in
            store.observeStats(timeZone: zone, now: clock, onError: onError, onChange: onChange)
        }
        model.deactivate()
        model.activate()
        await waitUntil { model.error == nil && model.snapshot != nil }
        #expect(model.error == nil)
        model.deactivate()
    }
}
