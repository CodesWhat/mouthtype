import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

/// The SQL aggregates must give exactly what the old fetch-every-sample path gave.
@Suite struct StatsAggregatesTests {
    private struct Lcg {
        var state: UInt64
        mutating func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
    }

    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-agg-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    private func insert(_ store: TranscriptStore, day: String, at: Double, words: Int?, voiced: Int?, audio: Int?, secure: Int?) throws {
        try store.pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, words_final, voiced_ms, audio_ms, is_secure)
                    VALUES (?, ?, 0, ?, 'dictate', 'hold', 'inserted', ?, ?, ?, ?)
                    """, arguments: [UUID().uuidString, at, day, words, voiced, audio, secure])
        }
    }

    private func compare(_ store: TranscriptStore, now: Date) throws {
        let zone = TimeZone(secondsFromGMT: 0)!
        let old = StatsSnapshot.make(samples: try store.statsSamples(), now: now, timeZone: zone)
        let new = try store.statsSnapshot(now: now, timeZone: zone)
        #expect(new == old)
    }

    @Test func aggregatesMatchTheSampleComputationOnSyntheticHistories() throws {
        let now = Date(timeIntervalSince1970: 1_792_000_000)  // 2026-10-14 UTC
        for seed in 1...8 {
            let (store, dir) = try makeStore()
            defer { try? FileManager.default.removeItem(at: dir) }
            var rng = Lcg(state: UInt64(seed))
            for _ in 0..<150 {
                let day = Double(rng.next(60)) * 86_400
                let at = 1_787_000_000 + day + Double(rng.next(3)) * 60  // few distinct times, so ties happen
                let dayString = Streaks.localDay(for: Date(timeIntervalSince1970: at), in: TimeZone(secondsFromGMT: 0)!)
                let words: Int? = [nil, 0, 1, 4, 5, 5, 12, 30, 30, 90, 400][rng.next(11)]
                // Durations include the 3 s floor, the 400 WPM ceiling (5 words in 750 ms is exactly 400), and nulls.
                let ms: Int? = [nil, 0, 2_999, 3_000, 3_000, 4_500, 9_000, 20_000, 750][rng.next(9)]
                let useVoiced = rng.next(2) == 0
                try insert(
                    store, day: dayString, at: at, words: words, voiced: useVoiced ? ms : nil,
                    audio: useVoiced ? 1_000 : ms, secure: [nil, 0, 0, 1][rng.next(4)])
            }
            try compare(store, now: now)
            try compare(store, now: now.addingTimeInterval(40 * 86_400))
        }
    }

    @Test func exactly400WPMCountsAndAboveItDoesNot() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-10-14", at: 1_000, words: 20, voiced: 3_000, audio: nil, secure: nil)  // 400
        try insert(store, day: "2026-10-14", at: 2_000, words: 21, voiced: 3_000, audio: nil, secure: nil)  // 420, ignored
        let snapshot = try store.statsSnapshot(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(snapshot.report.bestWPM == 400)
        #expect(snapshot.records.wpm == Record(value: 400, setOn: "2026-10-14"))
        try compare(store, now: Date(timeIntervalSince1970: 1_792_000_000))
    }

    @Test func tiesGoToTheEarliestTake() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        try insert(store, day: "2026-10-13", at: 2_000, words: 30, voiced: 6_000, audio: nil, secure: nil)
        try insert(store, day: "2026-10-10", at: 1_000, words: 30, voiced: 6_000, audio: nil, secure: nil)
        let snapshot = try store.statsSnapshot(now: Date(timeIntervalSince1970: 1_792_000_000), timeZone: TimeZone(secondsFromGMT: 0)!)
        #expect(snapshot.records.wpm?.setOn == "2026-10-10")
        #expect(snapshot.records.longestDictation?.setOn == "2026-10-10")
    }
}
