import CryptoKit
import Foundation
import GRDB
@testable import MouthtypeCore

/// Reads a saved database without going through `TranscriptStore`, so a test can compare what the file held before and
/// after the store opened it.
enum SavedData {
    struct State: Equatable {
        var schema: [String]
        var rows: [String: Int]
        var digests: [String: String]
    }

    static func state(_ url: URL) throws -> State {
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

    static func copyDatabase(from source: URL, to destination: URL) throws {
        var configuration = Configuration()
        configuration.readonly = true
        let reader = try DatabaseQueue(path: source.path, configuration: configuration)
        let writer = try DatabaseQueue(path: destination.path)
        try reader.backup(to: writer)
    }

    /// The rowids `take_search` should hold: rows with usable text outside secure fields. Written out here on purpose
    /// rather than shared with the migration, so a drift in either shows up.
    static let eligibleRowidsSQL = """
        SELECT rowid FROM dictation
        WHERE final_text IS NOT NULL AND TRIM(final_text) != '' AND COALESCE(is_secure, 0) = 0 ORDER BY rowid
        """

    static func eligibleRowids(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: eligibleRowidsSQL)
    }

    static func indexedRowids(_ db: Database) throws -> [Int64] {
        try Int64.fetchAll(db, sql: "SELECT rowid FROM take_search ORDER BY rowid")
    }

    static func newTemporaryDirectory(_ label: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func fixtureURL(_ name: String, filePath: String = #filePath) -> URL {
        URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("Fixtures").appendingPathComponent(name)
    }

    /// Builds a database file from a committed fixture script.
    static func loadFixture(_ name: String, into url: URL) throws {
        let sql = try String(contentsOf: fixtureURL(name), encoding: .utf8)
        let queue = try DatabaseQueue(path: url.path)
        try queue.write { db in try db.execute(sql: sql) }
    }
}
