import CryptoKit
import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct SavedDataCompatibilityTests {
    private struct State: Equatable {
        var schema: [String]
        var rows: [String: Int]
        var digests: [String: String]
    }

    private func state(_ url: URL) throws -> State {
        return try DatabaseQueue(path: url.path).read { db in
            let schema = try String.fetchAll(db, sql: "SELECT type || ':' || name || ':' || COALESCE(sql, '') FROM sqlite_master ORDER BY type, name")
            var counts: [String: Int] = [:]
            var digests: [String: String] = [:]
            for table in ["dictation", "edit_op", "correction"] {
                var digest = SHA256()
                var count = 0
                let cursor = try Row.fetchCursor(db, sql: "SELECT * FROM \(table) ORDER BY id")
                while let row = try cursor.next() {
                    count += 1
                    for value in row.databaseValues {
                        let type: String
                        let data: Data
                        switch value.storage {
                        case .null: type = "null"; data = Data()
                        case .int64(let value): type = "integer"; data = Data(String(value).utf8)
                        case .double(let value): type = "real"; data = Data(String(value.bitPattern).utf8)
                        case .string(let value): type = "text"; data = Data(value.utf8)
                        case .blob(let value): type = "blob"; data = value
                        }
                        digest.update(data: Data("\(type):\(data.count):".utf8))
                        digest.update(data: data)
                    }
                }
                counts[table] = count
                digests[table] = digest.finalize().map { String(format: "%02x", $0) }.joined()
            }
            return State(schema: schema, rows: counts, digests: digests)
        }
    }

    private func copyDatabase(from source: URL, to destination: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: source.path, configuration: configuration)
        let writer = try DatabaseQueue(path: destination.path)
        try reader.backup(to: writer)
    }

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
        try copyDatabase(from: source, to: copy)
        let copied = try DatabaseQueue(path: copy.path).read { db -> String? in
            guard try db.tableExists("pending_write") else { return nil }
            return try String.fetchOne(db, sql: "SELECT value FROM pending_write")
        }
        #expect(copied == "preserved")
        withExtendedLifetime(pool) {}
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["MOUTHTYPE_COMPAT_DATABASE"] != nil))
    func reopeningAnExistingSnapshotPreservesItsSchemaAndEveryStoredValue() throws {
        let path = try #require(ProcessInfo.processInfo.environment["MOUTHTYPE_COMPAT_DATABASE"])
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-compat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let copy = directory.appendingPathComponent("snapshot.sqlite")
        try copyDatabase(from: URL(fileURLWithPath: path), to: copy)
        let before = try state(copy)
        let store = try TranscriptStore(url: copy)
        _ = try store.recent(limit: 1)
        let after = try state(copy)
        #expect(before == after)
        withExtendedLifetime(store) {}
    }
}
