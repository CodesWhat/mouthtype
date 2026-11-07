import CryptoKit
import Foundation
import GRDB
import Synchronization
import Testing
@testable import MouthtypeCore

/// Databases as released versions left them, opened by the current code. The fixtures are synthetic scripts built from the
/// schema at each tag (`Fixtures/schema-<tag>.sql`).
@Suite struct SchemaUpgradeFixtureTests {
    private struct Fixture: CustomTestStringConvertible, Sendable {
        let tag: String
        let applied: [String]
        var file: String { "schema-\(tag).sql" }
        var testDescription: String { tag }
    }

    private static let fixtures = [
        Fixture(tag: "v0.1.0", applied: ["v1", "v2"]),
        Fixture(tag: "v0.3.0", applied: ["v1", "v2", "v3"]),
        Fixture(tag: "v0.10.0", applied: ["v1", "v2", "v3", "v4-history-search"]),
    ]

    private let now = Date(timeIntervalSince1970: 1_791_806_400)
    private let utc = TimeZone(identifier: "UTC")!

    @Test(arguments: SchemaUpgradeFixtureTests.fixtures)
    private func releasedDatabaseUpgradesWithEveryRowIntact(_ fixture: Fixture) throws {
        let directory = try SavedData.newTemporaryDirectory("upgrade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mouthtype.sqlite")
        try SavedData.loadFixture(fixture.file, into: url)

        let before = try SavedData.state(url)
        #expect(before.rows == ["dictation": 27, "edit_op": 4, "correction": 3])
        let appliedBefore = try DatabaseQueue(path: url.path).read { try TranscriptStore.migrator.appliedMigrations($0) }
        #expect(appliedBefore == fixture.applied)

        let store = try TranscriptStore(url: url)

        let after = try SavedData.state(url)
        #expect(after.rows == before.rows)
        #expect(after.digests == before.digests)

        try store.pool.read { db in
            let migrator = TranscriptStore.migrator
            try #expect(migrator.appliedMigrations(db) == ["v1", "v2", "v3", "v4-history-search"])
            try #expect(migrator.appliedMigrations(db) == migrator.migrations)
            try #expect(!migrator.hasBeenSuperseded(db))
            let eligible = try SavedData.eligibleRowids(db)
            #expect(eligible.count == 6)
            try #expect(SavedData.indexedRowids(db) == eligible)
            try #expect(db.indexes(on: "dictation").contains { $0.name == "dictation_stats" })
        }

        // Search: matches only indexed rows, so secure rows and rows without final text never show.
        try #expect(store.recentTakes(limit: 100).count == 6)
        try #expect(store.recentTakes(limit: 100, query: "alpha").count == 2)
        try #expect(store.recentTakes(limit: 100, query: "streak").count == 3)
        try #expect(store.recentTakes(limit: 100, query: "omega").isEmpty)

        _ = try store.stats(now: now, timeZone: utc)
        _ = try store.statsSnapshot(now: now, timeZone: utc)
        let extras = try store.achievementExtras(calibrated: false)
        #expect(extras.days.count == 5)

        // Last: recovery ends the unfinished rows, which changes them.
        let archive = AudioArchive(supportDirectory: directory)
        let scan = try DictationRecovery.scan(store: store, archive: archive, now: now, launchedAt: now)
        #expect(scan.lostCount == 5)
        #expect(scan.newest == nil)
        let interrupted = try #require(try store.dictation(id: "00000000-0000-0000-0000-000000000027"))
        #expect(interrupted.status == .failed)
        #expect(interrupted.errorMessage == DictationRecovery.interruptedMessage)
        try #expect(store.unfinished(from: now.addingTimeInterval(-DictationRecovery.window), before: now).isEmpty)
    }

    /// Shipped migrations must never be edited: a user already past one never re-runs it, so a changed body would split
    /// the installed base into two schemas.
    @Test func shippedMigrationsAreFrozen() throws {
        let perMigration = try Self.statementsRunByEachMigration()
        let frozen: [String: String] = [
            "v1": "b12266add80596eca3c45bad5503874431d094837477eb41ae0b82c5eb05d43e",
            "v2": "04553230b097f1f75828436e7cc2d9eaad6b36b7e08a747bc8f71d35eba7c51d",
            "v3": "99fe5885ae26bf77fc88e78e1cf56d17d59870924e942266d75e78f068f4385b",
            "v4-history-search": "34dc0afe574e0ff321d8dd74300290aea543678e48623768062b45be23c93b83",
        ]
        for (id, expected) in frozen {
            let actual = Self.hash(perMigration[id] ?? [])
            #expect(
                actual == expected,
                "Migration \(id) changed after it shipped. Don't edit it in place: databases that already ran it won't run it again. Add a new migration instead. (hash \(actual))"
            )
        }
    }

    /// The SQL each registered migration executes, traced on a scratch database, whitespace collapsed. GRDB's own
    /// bookkeeping statements are left out.
    private static func statementsRunByEachMigration() throws -> [String: [String]] {
        let seen = Mutex<[String]>([])
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace(options: .statement) { event in
                guard case .statement(let statement) = event else { return }
                let sql = statement.sql.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                let upper = sql.uppercased()
                let bookkeeping = ["SAVEPOINT", "RELEASE", "BEGIN", "COMMIT", "ROLLBACK", "PRAGMA", "--"]
                guard !sql.isEmpty, !sql.contains("grdb_migrations"), !bookkeeping.contains(where: upper.hasPrefix) else { return }
                seen.withLock { $0.append(sql) }
            }
        }
        let queue = try DatabaseQueue(configuration: configuration)
        let migrator = TranscriptStore.migrator
        var result: [String: [String]] = [:]
        for id in migrator.migrations {
            try migrator.migrate(queue, upTo: id)
            result[id] = seen.withLock { statements in
                defer { statements.removeAll() }
                return statements
            }
        }
        return result
    }

    private static func hash(_ statements: [String]) -> String {
        SHA256.hash(data: Data(statements.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// An older build opening a newer database: it knows only the first migrations, sees the rest as unknown, runs
    /// nothing, and writes through the triggers the newer schema left behind.
    @Test func olderBuildWritingToANewerDatabaseLeavesNextLaunchConsistent() throws {
        let directory = try SavedData.newTemporaryDirectory("downgrade")
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("mouthtype.sqlite")
        try SavedData.loadFixture("schema-v0.3.0.sql", into: url)
        do { _ = try TranscriptStore(url: url) }
        let current = try SavedData.state(url)

        // GRDB's `migrate(upTo:)` fatal-errors on a database that is past its target, so the older build is modelled the
        // way it behaves at launch: a migrator that registers only what it shipped. Those bodies never run here.
        var older = DatabaseMigrator()
        for id in ["v1", "v2", "v3"] { older.registerMigration(id) { _ in Issue.record("older migrator ran \(id)") } }
        let pool = try DatabasePool(path: url.path)
        try older.migrate(pool)
        try pool.read { db in
            try #expect(older.hasBeenSuperseded(db))
            try #expect(older.appliedIdentifiers(db) == ["v1", "v2", "v3", "v4-history-search"])
        }
        try pool.write { db in
            try db.execute(
                sql: """
                    INSERT INTO dictation (id, started_at, utc_offset_s, local_day, mode, trigger, status, raw_text, final_text,
                        words_final, app_name, is_secure)
                    VALUES ('older-visible', 1791900000, 0, '2026-10-13', 'hold', 'fn', 'inserted', 'zebra raw', 'Zebra final', 2, 'Notes', 0),
                           ('older-secure', 1791900100, 0, '2026-10-13', 'hold', 'fn', 'inserted', 'zebra secret', 'Zebra secret', 2, 'Notes', 1);
                    UPDATE dictation SET final_text = '' WHERE id = '00000000-0000-0000-0000-000000000004';
                    DELETE FROM dictation WHERE id = '00000000-0000-0000-0000-000000000023';
                    """)
        }

        let store = try TranscriptStore(url: url)
        try store.pool.read { db in
            let migrator = TranscriptStore.migrator
            try #expect(migrator.appliedMigrations(db) == migrator.migrations)
            try #expect(!migrator.hasBeenSuperseded(db))
            try #expect(SavedData.indexedRowids(db) == SavedData.eligibleRowids(db))
        }
        try store.pool.write { db in
            try db.execute(sql: "INSERT INTO take_search(take_search) VALUES ('integrity-check')")
        }
        try #expect(store.recentTakes(limit: 100, query: "zebra").map(\.id) == ["older-visible"])
        try #expect(SavedData.state(url).schema == current.schema)
    }
}
