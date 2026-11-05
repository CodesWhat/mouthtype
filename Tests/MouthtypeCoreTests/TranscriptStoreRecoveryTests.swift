import Foundation
import GRDB
import Testing
@testable import MouthtypeCore

@Suite struct TranscriptStoreRecoveryTests {
    @Test(arguments: [false, true]) func damagedSearchIndexIsRepairedWithoutQuarantiningHistory(damagesContent: Bool) throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-fts-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.sqlite")
        let audio = dir.appendingPathComponent("audio", isDirectory: true)
        try FileManager.default.createDirectory(at: audio, withIntermediateDirectories: true)
        let recording = audio.appendingPathComponent("kept.wav")
        try Data("recording".utf8).write(to: recording)
        var id = ""
        var segment = Data()
        var contentPage = 0
        var pageSize = 0
        do {
            let store = try TranscriptStore(url: url)
            id = try store.begin(DictationStart(startedAt: Date(timeIntervalSince1970: 1_000)))
            try store.recordInsertion(id, InsertionRecord(finalText: "spoken words"))
            #expect(try store.recentTakes(limit: 5, query: "spoken").map(\.id) == [id])
            let secure = try store.begin(DictationStart(startedAt: Date(timeIntervalSince1970: 1_001)))
            try store.recordInsertion(secure, InsertionRecord(finalText: "confidential phrase", target: DictationTarget(isSecure: true)))
            segment = try store.pool.read { db in
                contentPage = try #require(try Int.fetchOne(db, sql: "SELECT rootpage FROM sqlite_master WHERE name = 'take_search_content'"))
                pageSize = try #require(try Int.fetchOne(db, sql: "PRAGMA page_size"))
                return try #require(try Data.fetchOne(db, sql: "SELECT block FROM take_search_data WHERE id > 10 ORDER BY id LIMIT 1"))
            }
        }
        var bytes = try Data(contentsOf: url)
        let range = try #require(bytes.range(of: segment))
        #expect(bytes.range(of: segment, in: range.upperBound..<bytes.endIndex) == nil)
        bytes.replaceSubrange(range, with: Data(repeating: 0, count: segment.count))
        if damagesContent {
            let pageStart = (contentPage - 1) * pageSize
            let contentRange = try #require(bytes.range(of: Data("spoken words".utf8), in: pageStart..<(pageStart + pageSize)))
            bytes.replaceSubrange(contentRange, with: Data("broken words".utf8))
        }
        try bytes.write(to: url)
        let outcome = TranscriptStoreOpener.open(url: url, audioDirectory: audio)
        #expect(outcome.failure == nil)
        #expect(outcome.quarantinedTo == nil)
        let store = try #require(outcome.store)
        #expect(try store.dictation(id: id)?.finalText == "spoken words")
        #expect(try Data(contentsOf: recording) == Data("recording".utf8))
        #expect(try store.recentTakes(limit: 5, query: "spoken").map(\.id) == [id])
        #expect(try store.recentTakes(limit: 5, query: "confidential").isEmpty)
        #expect(try store.recentTakes(limit: 5, query: "broken").isEmpty)
        let next = try store.begin(DictationStart(startedAt: Date(timeIntervalSince1970: 2_000)))
        try store.recordInsertion(next, InsertionRecord(finalText: "subsequent words"))
        #expect(try store.recentTakes(limit: 5, query: "subsequent").map(\.id) == [next])
        try store.recordInsertion(next, InsertionRecord(finalText: "private phrase", target: DictationTarget(isSecure: true)))
        #expect(try store.recentTakes(limit: 5, query: "private").isEmpty)
    }
}
