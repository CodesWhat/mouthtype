import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct TranscriptStoreRecoveryTests {
    @Test func damagedSearchIndexIsRepairedWithoutQuarantiningHistory() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-fts-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        let audio = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let recording = audio.appendingPathComponent("kept.wav")
        try Data("recording".utf8).write(to: recording)
        var id = ""
        var segment = Data()
        do {
            let store = try TranscriptStore(url: url)
            id = try store.begin(DictationStart(startedAt: Date(timeIntervalSince1970: 1_000)))
            try store.recordInsertion(id, InsertionRecord(finalText: "spoken words"))
            #expect(try store.recentTakes(limit: 5, query: "spoken").map(\.id) == [id])
            segment = try store.pool.read { db in
                try #require(try Data.fetchOne(db, sql: "SELECT block FROM take_search_data WHERE id > 10 ORDER BY id LIMIT 1"))
            }
        }
        var bytes = try Data(contentsOf: url)
        let range = try #require(bytes.range(of: segment))
        #expect(bytes.range(of: segment, in: range.upperBound..<bytes.endIndex) == nil)
        bytes.replaceSubrange(range, with: Data(repeating: 0, count: segment.count))
        try bytes.write(to: url)
        let outcome = TranscriptStoreOpener.open(url: url, audioDirectory: audio)
        #expect(outcome.failure == nil)
        #expect(outcome.quarantinedTo == nil)
        let store = try #require(outcome.store)
        #expect(try store.dictation(id: id)?.finalText == "spoken words")
        #expect(try Data(contentsOf: recording) == Data("recording".utf8))
        #expect(try store.recentTakes(limit: 5, query: "spoken").map(\.id) == [id])
        let next = try store.begin(DictationStart(startedAt: Date(timeIntervalSince1970: 2_000)))
        try store.recordInsertion(next, InsertionRecord(finalText: "subsequent words"))
        #expect(try store.recentTakes(limit: 5, query: "subsequent").map(\.id) == [next])
        try store.recordInsertion(next, InsertionRecord(finalText: "private phrase", target: DictationTarget(isSecure: true)))
        #expect(try store.recentTakes(limit: 5, query: "private").isEmpty)
    }
}
