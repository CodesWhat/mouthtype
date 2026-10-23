import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioArchiveTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func samples(_ count: Int) -> [Float] {
        (0..<count).map { 0.5 * sin(Float($0) * 0.05) }
    }

    @Test func writeAndReadRoundTrip() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let input = samples(1600)
        let entry = try archive.write(samples: input, id: "abc")

        #expect(entry.url == dir.appendingPathComponent("audio/abc.wav"))
        #expect(entry.byteSize == 44 + 1600 * 2)
        #expect(try FileManager.default.attributesOfItem(atPath: entry.url.path)[.size] as? Int == entry.byteSize)

        let output = try archive.read(id: "abc")
        #expect(output.count == input.count)
        for (a, b) in zip(input, output) { #expect(abs(a - b) < 1.0 / 16_000) }
    }

    @Test func headerDescribes16kMono16Bit() throws {
        let data = AudioArchive.wavData(samples: samples(100))
        #expect(String(decoding: data[0..<4], as: UTF8.self) == "RIFF")
        #expect(String(decoding: data[8..<16], as: UTF8.self) == "WAVEfmt ")
        #expect(data[22] == 1)  // channels
        #expect(data[24] == 0x80 && data[25] == 0x3E)  // 16000 Hz little endian
        #expect(data[34] == 16)  // bits per sample
    }

    @Test func rejectsNonWav() {
        #expect(throws: AudioArchive.ArchiveError.notWav) { try AudioArchive.samples(fromWAV: Data("hello".utf8)) }
    }

    private func setAge(_ archive: AudioArchive, id: String, daysAgo: Double, now: Date) throws {
        try FileManager.default.setAttributes(
            [.modificationDate: now.addingTimeInterval(-daysAgo * 86_400)], ofItemAtPath: archive.url(for: id).path
        )
    }

    @Test func purgesByAge() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for id in ["old", "mid", "new"] { try archive.write(samples: samples(160), id: id) }
        try setAge(archive, id: "old", daysAgo: 120, now: now)
        try setAge(archive, id: "mid", daysAgo: 30, now: now)
        try setAge(archive, id: "new", daysAgo: 1, now: now)

        let removed = try archive.purge(olderThan: now.addingTimeInterval(-AudioArchive.defaultRetention))
        #expect(removed == ["old"])
        #expect(!FileManager.default.fileExists(atPath: archive.url(for: "old").path))
        #expect(FileManager.default.fileExists(atPath: archive.url(for: "mid").path))
    }

    @Test func purgesOldestFirstBySize() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for (id, age) in [("a", 3.0), ("b", 2.0), ("c", 1.0)] {
            try archive.write(samples: samples(1000), id: id)  // 2044 bytes each
            try setAge(archive, id: id, daysAgo: age, now: now)
        }
        let removed = try archive.purge(olderThan: now.addingTimeInterval(-86_400 * 90), maxTotalBytes: 2 * 2044 + 10)
        #expect(removed == ["a"])
        #expect(FileManager.default.fileExists(atPath: archive.url(for: "b").path))

        let more = try archive.purge(olderThan: now.addingTimeInterval(-86_400 * 90), maxTotalBytes: 0)
        #expect(more == ["b", "c"])
    }

    @Test func purgeWithNoDirectoryIsEmpty() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        #expect(try AudioArchive(supportDirectory: dir).purge(olderThan: Date()) == [])
    }

    @Test func completedAudioPurgePreservesCrashRecoveryPartials() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        try archive.write(samples: samples(160), id: "completed")
        try archive.appendPartial(samples: samples(160), id: "interrupted")
        let partial = archive.partialURL(for: "interrupted")
        let original = try Data(contentsOf: partial)
        let removed = try archive.purge(olderThan: Date.distantFuture, maxTotalBytes: 0)
        #expect(removed == ["completed"])
        #expect(FileManager.default.fileExists(atPath: partial.path))
        if FileManager.default.fileExists(atPath: partial.path) {
            #expect(try Data(contentsOf: partial) == original)
        }
    }

    @Test func retentionOnlyCountsSelectedCompletedTakesAgainstTheLimit() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let archive = AudioArchive(supportDirectory: dir)
        let now = Date()
        for (id, age) in [("unfinished", 120.0), ("completed", 30.0)] {
            try archive.write(samples: samples(160), id: id)
            try setAge(archive, id: id, daysAgo: age, now: now)
        }
        let original = try Data(contentsOf: archive.url(for: "unfinished"))
        let removed = try archive.purge(olderThan: now.addingTimeInterval(-90 * 86_400), maxTotalBytes: 364, eligibleIDs: ["completed"])
        #expect(removed.isEmpty)
        #expect(try Data(contentsOf: archive.url(for: "unfinished")) == original)
        #expect(FileManager.default.fileExists(atPath: archive.url(for: "completed").path))
        let purged = try archive.purge(olderThan: now.addingTimeInterval(-14 * 86_400), maxTotalBytes: 0, eligibleIDs: ["completed"])
        #expect(purged == ["completed"])
        #expect(try Data(contentsOf: archive.url(for: "unfinished")) == original)
    }
}
