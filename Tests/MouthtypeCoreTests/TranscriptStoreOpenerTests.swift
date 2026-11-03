import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct TranscriptStoreOpenerTests {
    private static func makeDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-opener-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func nonSQLiteFileIsQuarantinedAndAFreshStoreOpens() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        let junk = Data("this is not a database, it is just some text long enough to look wrong".utf8)
        try junk.write(to: url)
        let audio = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: audio.appendingPathComponent("old.wav"))

        let outcome = TranscriptStoreOpener.open(url: url, now: { Date(timeIntervalSince1970: 0) })

        #expect(outcome.store != nil)
        #expect(outcome.failure == nil)
        let moved = try #require(outcome.quarantinedTo)
        #expect(moved.lastPathComponent == "mouthtype.sqlite.corrupt-19700101T000000Z")
        #expect(try Data(contentsOf: moved) == junk)
        let movedAudio = try #require(outcome.quarantinedAudioTo)
        #expect(movedAudio.lastPathComponent == "audio.corrupt-19700101T000000Z")
        #expect(try Data(contentsOf: movedAudio.appendingPathComponent("old.wav")) == Data("wav".utf8))
        #expect(!FileManager.default.fileExists(atPath: audio.path))
        #expect(outcome.quarantineNotice?.contains("audio.corrupt-") == true)
        #expect(outcome.quarantineNotice?.contains(moved.lastPathComponent) == true)
        // The fresh store is usable.
        _ = try outcome.store?.stats(now: Date())
    }

    @Test func quarantineMovesTheWalAndShmAlongside() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        try Data("db".utf8).write(to: url)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))
        let audio = dir.appendingPathComponent("audio", isDirectory: true)
        let moved = try TranscriptStoreOpener.quarantine(url, audio: audio, at: Date(timeIntervalSince1970: 0)).get().database
        #expect(try Data(contentsOf: moved) == Data("db".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal.corrupt-19700101T000000Z")) == Data("wal".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-shm.corrupt-19700101T000000Z")) == Data("shm".utf8))
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test func healthyStoreOpensWithNothingReported() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let outcome = TranscriptStoreOpener.open(url: dir.appendingPathComponent("mouthtype.sqlite"))
        #expect(outcome.store != nil && outcome.quarantinedTo == nil && outcome.failure == nil)
    }

    @Test func busyIsRetriedOnceAfterTheDelay() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        var attempts = 0
        var slept: [TimeInterval] = []
        let outcome = TranscriptStoreOpener.open(
            url: url, retryDelay: 0.25, sleep: { slept.append($0) },
            opener: { u in
                attempts += 1
                if attempts == 1 { throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked") }
                return try TranscriptStore(url: u)
            })
        #expect(outcome.store != nil && outcome.failure == nil && outcome.quarantinedTo == nil)
        #expect(attempts == 2)
        #expect(slept == [0.25])
    }

    @Test func persistentBusyReportsAFailureAndLeavesTheFileAlone() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        try Data("keep me".utf8).write(to: url)
        var attempts = 0
        let outcome = TranscriptStoreOpener.open(
            url: url, sleep: { _ in },
            opener: { _ in
                attempts += 1
                throw DatabaseError(resultCode: .SQLITE_BUSY, message: "database is locked")
            })
        #expect(outcome.store == nil)
        #expect(outcome.failure == "database is locked")
        #expect(attempts == 2)
        #expect(try Data(contentsOf: url) == Data("keep me".utf8))
    }

    @Test func otherErrorsAreNotRetriedOrQuarantined() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        try Data("keep me".utf8).write(to: url)
        var attempts = 0
        let outcome = TranscriptStoreOpener.open(
            url: url, sleep: { _ in Issue.record("slept on a non-busy error") },
            opener: { _ in
                attempts += 1
                throw DatabaseError(resultCode: .SQLITE_FULL, message: "database or disk is full")
            })
        #expect(outcome.store == nil && outcome.quarantinedTo == nil)
        #expect(outcome.failure == "database or disk is full")
        #expect(attempts == 1)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    @Test func corruptFileThatCantBeReplacedStillKeepsTheQuarantine() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        try Data("junk".utf8).write(to: url)
        let outcome = TranscriptStoreOpener.open(
            url: url, opener: { _ in throw DatabaseError(resultCode: .SQLITE_CORRUPT, message: "malformed") })
        #expect(outcome.store == nil)
        #expect(outcome.quarantinedTo != nil)
        #expect(outcome.failure == "malformed")
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    private struct MoveFailed: Error {}

    /// A db with -wal, -shm and an audio folder, all present.
    private static func makeDamaged(in dir: URL) throws -> (url: URL, audio: URL) {
        let url = dir.appendingPathComponent("mouthtype.sqlite")
        try Data("db".utf8).write(to: url)
        try Data("wal".utf8).write(to: URL(fileURLWithPath: url.path + "-wal"))
        try Data("shm".utf8).write(to: URL(fileURLWithPath: url.path + "-shm"))
        let audio = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        try Data("wav".utf8).write(to: audio.appendingPathComponent("a.wav"))
        return (url, audio)
    }

    private static func damaged(_ url: URL, mover: (URL, URL) throws -> Void) -> StoreOpenOutcome {
        TranscriptStoreOpener.open(
            url: url, opener: { _ in throw DatabaseError(resultCode: .SQLITE_NOTADB, message: "file is not a database") }, mover: mover)
    }

    @Test(arguments: [2, 3, 4]) func aFailedMoveRollsEverythingBack(failingMove: Int) throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, audio) = try Self.makeDamaged(in: dir)
        var count = 0
        let outcome = Self.damaged(url) { from, to in
            count += 1
            if count == failingMove { throw MoveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(outcome.store == nil)
        #expect(outcome.quarantinedTo == nil)
        #expect(outcome.failure?.contains("couldn't be set aside") == true)
        #expect(try Data(contentsOf: url) == Data("db".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) == Data("wal".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-shm")) == Data("shm".utf8))
        #expect(try Data(contentsOf: audio.appendingPathComponent("a.wav")) == Data("wav".utf8))
        let names = try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
        #expect(names == ["audio", "mouthtype.sqlite", "mouthtype.sqlite-shm", "mouthtype.sqlite-wal"])
    }

    @Test func audioMoveFailingLeavesTheDatabaseUntouched() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, audio) = try Self.makeDamaged(in: dir)
        let outcome = Self.damaged(url) { from, to in
            if from == audio { throw MoveFailed() }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(outcome.store == nil && outcome.quarantinedTo == nil)
        #expect(outcome.failure != nil)
        #expect(try Data(contentsOf: url) == Data("db".utf8))
        #expect(try Data(contentsOf: URL(fileURLWithPath: url.path + "-wal")) == Data("wal".utf8))
    }

    @Test func aFailedRollbackReportsWhatIsStillMoved() throws {
        let dir = try Self.makeDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let (url, _) = try Self.makeDamaged(in: dir)
        var count = 0
        let outcome = Self.damaged(url) { from, to in
            count += 1
            // Moves 1-3 succeed, 4 (the database) fails, and moving the -wal back also fails.
            if count == 4 || from.lastPathComponent.contains("-wal.corrupt-") {
                throw MoveFailed()
            }
            try FileManager.default.moveItem(at: from, to: to)
        }
        #expect(outcome.store == nil)
        #expect(outcome.quarantinedTo == nil)
        #expect(outcome.failure?.contains("mouthtype.sqlite-wal.corrupt-") == true)
        #expect(outcome.failure?.contains("could not be moved back") == true)
    }
}
