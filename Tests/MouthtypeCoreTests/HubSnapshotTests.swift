import Foundation
import MLXLMCommon
import Testing
@testable import MouthtypeCore

private struct CachedFiles {
    var entries: [String: Data] = [
        "config.json": Data("{\"model_type\":\"qwen3\"}".utf8),
        "tokenizer.json": Data("{\"model\":{\"type\":\"BPE\"}}".utf8),
        "model.safetensors": Data([1]),
    ]
    var isComplete: Bool {
        HubDownloader.snapshotIsComplete(files: Array(entries.keys),
            fileExists: { entries[$0]?.isEmpty == false }, contents: { entries[$0] })
    }
}

private final class DownloadProbe: Downloader, @unchecked Sendable {
    private let lock = NSLock()
    private var requests: [Bool] = []
    var latest: [Bool] { lock.withLock { requests } }
    func download(id: String, revision: String?, matching patterns: [String], useLatest: Bool,
                  progressHandler: @Sendable @escaping (Progress) -> Void) async throws -> URL {
        lock.withLock { requests.append(useLatest) }
        progressHandler(Progress(totalUnitCount: 1))
        return URL(fileURLWithPath: "/virtual/model")
    }
}

@Suite struct HubSnapshotTests {
    @Test(arguments: ["config.json", "tokenizer.json", "model.safetensors"], [false, true])
    func interruptedRequiredDownloadsAreNotReady(missing: String, empty: Bool) {
        var cache = CachedFiles()
        cache.entries[missing] = empty ? Data() : nil
        #expect(!cache.isComplete)
    }

    @Test func completeSingleFileAndShardedSnapshotsStayUsableOffline() {
        var cache = CachedFiles()
        #expect(cache.isComplete)
        cache.entries["model.safetensors"] = nil
        cache.entries["part1.safetensors"] = Data([1])
        cache.entries["part2.safetensors"] = Data([2])
        cache.entries["model.safetensors.index.json"] = Data("{\"weight_map\":{\"a\":\"part1.safetensors\",\"b\":\"part2.safetensors\"}}".utf8)
        #expect(cache.isComplete)
        cache.entries["part2.safetensors"] = nil
        #expect(!cache.isComplete)
    }

    @Test(arguments: ["{}", "{\"weight_map\":{}}", "broken"])
    func interruptedIndexNeverFallsBackToAnArbitraryPresentShard(index: String) {
        var cache = CachedFiles()
        cache.entries["model.safetensors.index.json"] = Data(index.utf8)
        #expect(!cache.isComplete)
    }

    @Test func explicitDownloadRepairsInsteadOfTakingTheReadinessShortcut() async throws {
        let probe = DownloadProbe()
        let spec = try #require(CleanerCatalog.mlxSpec(id: "superwhisper-s1-mini"))
        let cleaner = MLXCleaner(spec: spec, downloadSource: probe)
        try await cleaner.download { _ in }
        #expect(!probe.latest.isEmpty && probe.latest.allSatisfy { $0 })
    }
}
