import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct SavedDataCompatibilityTests {
    @Test func copyingIncludesCommittedRowsStillInTheWriteAheadLog() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-wal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("source.sqlite")
        let pool = try DatabasePool(path: source.path)
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA wal_autocheckpoint = 0")
            try db.execute(sql: "CREATE TABLE pending_write (value TEXT); INSERT INTO pending_write VALUES ('preserved')")
        }
        let copy = directory.appendingPathComponent("copy.sqlite")
        try SavedData.copyDatabase(from: source, to: copy)
        let copied = try DatabaseQueue(path: copy.path).read { db -> String? in
            guard try db.tableExists("pending_write") else { return nil }
            return try String.fetchOne(db, sql: "SELECT value FROM pending_write")
        }
        #expect(copied == "preserved")
        withExtendedLifetime(pool) {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHTYPE_COMPAT_DATABASE"] != nil))
    func upgradingAnExistingSnapshotKeepsEveryStoredValueAndLeavesItCurrent() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOUTHTYPE_COMPAT_DATABASE"])
        let directory = try SavedData.newTemporaryDirectory("compat")
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("snapshot.sqlite")
        try SavedData.copyDatabase(from: URL(fileURLWithPath: path), to: copy)
        let before = try SavedData.state(copy)
        let store = try TranscriptStore(url: copy)
        _ = try store.recent(limit: 1)
        let after = try SavedData.state(copy)
        // The schema is allowed to change: an older snapshot gains whatever migrations it was missing. Values are not.
        #expect(before.rows == after.rows)
        #expect(before.digests == after.digests)
        try store.pool.read { db in
            let migrator = TranscriptStore.migrator
            try #expect(migrator.appliedMigrations(db) == migrator.migrations)
            try #expect(SavedData.indexedRowids(db) == SavedData.eligibleRowids(db))
            try #expect(db.tableExists("take_search"))
        }
        withExtendedLifetime(store) {}
    }
}
