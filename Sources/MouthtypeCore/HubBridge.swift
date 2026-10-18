import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers
import os

/// Downloads model snapshots from the Hugging Face Hub, and serves a complete cached snapshot without touching the network.
struct HubDownloader: MLXLMCommon.Downloader {
    private let client = HubClient()
    /// Serve a complete cached snapshot or fail; never touch the network.
    var offline = false

    func download(
        id: String,
        revision: String?,
        matching patterns: [String],
        useLatest: Bool,
        progressHandler: @Sendable @escaping (Progress) -> Void
    ) async throws -> URL {
        guard let repo = Repo.ID(rawValue: id) else {
            throw CleanerError.failed("Invalid Hugging Face repository id '\(id)'")
        }
        let ref = revision ?? "main"
        if !useLatest || offline, let snapshot = Self.completeSnapshot(repo: repo, ref: ref) {
            return snapshot
        }
        if offline { throw CleanerError.unavailable(reason: "\(id) is not downloaded") }
        let logger = ProgressLogger(label: id)
        return try await client.downloadSnapshot(
            of: repo,
            revision: ref,
            matching: patterns,
            progressHandler: { @MainActor progress in
                logger.report(progress.fractionCompleted)
                progressHandler(progress)
            }
        )
    }

    static func cacheDirectory(for id: String) -> URL? {
        Repo.ID(rawValue: id).map { HubCache.default.repoDirectory(repo: $0, kind: .model) }
    }

    /// The commit the cached snapshot is at, or nil when nothing is cached.
    static func cachedRevision(id: String, revision: String = "main") -> String? {
        Repo.ID(rawValue: id).flatMap { HubCache.default.resolveRevision(repo: $0, kind: .model, ref: revision) }
    }

    static func isCached(id: String, revision: String = "main") -> Bool {
        guard let repo = Repo.ID(rawValue: id) else { return false }
        return completeSnapshot(repo: repo, ref: revision) != nil
    }

    private static func completeSnapshot(repo: Repo.ID, ref: String) -> URL? {
        let cache = HubCache.default
        guard let commit = cache.resolveRevision(repo: repo, kind: .model, ref: ref),
              let snapshot = try? cache.snapshotPath(repo: repo, kind: .model, commitHash: commit)
        else { return nil }
        let fm = FileManager.default
        return snapshotIsComplete(files: (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? [],
            fileExists: { fileIsNonempty(snapshot.appendingPathComponent($0)) },
            contents: { try? Data(contentsOf: snapshot.appendingPathComponent($0)) }) ? snapshot : nil
    }

    static func fileIsNonempty(_ url: URL) -> Bool {
        let fm = FileManager.default
        let path = url.resolvingSymlinksInPath().path
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &directory), !directory.boolValue else { return false }
        return (((try? fm.attributesOfItem(atPath: path)[.size]) as? NSNumber)?.intValue ?? 0) > 0
    }

    static func snapshotIsComplete(files: [String], fileExists: (String) -> Bool, contents: (String) -> Data?) -> Bool {
        guard fileExists("config.json"), fileExists("tokenizer.json") else { return false }
        if files.contains("model.safetensors.index.json") {
            guard let data = contents("model.safetensors.index.json"),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let weightMap = json["weight_map"] as? [String: String], !weightMap.isEmpty else { return false }
            return Set(weightMap.values).allSatisfy(fileExists)
        }
        return files.contains { $0.hasSuffix(".safetensors") && fileExists($0) }
    }
}

/// Prints download progress every 10 percent so a long first download is visible in the worker log.
final class ProgressLogger: Sendable {
    private let label: String
    private let lastDecile = OSAllocatedUnfairLock(initialState: -1)

    init(label: String) {
        self.label = label
    }

    func report(_ fraction: Double) {
        let decile = Int(max(0, min(1, fraction)) * 10)
        let isNew = lastDecile.withLock { last -> Bool in
            guard decile > last else { return false }
            last = decile
            return true
        }
        if isNew { print("[download \(label)] \(decile * 10)%") }
    }
}

struct TransformersTokenizerLoader: MLXLMCommon.TokenizerLoader {
    func load(from directory: URL) async throws -> any MLXLMCommon.Tokenizer {
        TokenizerBridge(try await AutoTokenizer.from(modelFolder: directory))
    }
}

private struct TokenizerBridge: MLXLMCommon.Tokenizer {
    private let upstream: any Tokenizers.Tokenizer

    init(_ upstream: any Tokenizers.Tokenizer) {
        self.upstream = upstream
    }

    func encode(text: String, addSpecialTokens: Bool) -> [Int] {
        upstream.encode(text: text, addSpecialTokens: addSpecialTokens)
    }

    func decode(tokenIds: [Int], skipSpecialTokens: Bool) -> String {
        upstream.decode(tokens: tokenIds, skipSpecialTokens: skipSpecialTokens)
    }

    func convertTokenToId(_ token: String) -> Int? {
        upstream.convertTokenToId(token)
    }

    func convertIdToToken(_ id: Int) -> String? {
        upstream.convertIdToToken(id)
    }

    var bosToken: String? { upstream.bosToken }
    var eosToken: String? { upstream.eosToken }
    var unknownToken: String? { upstream.unknownToken }

    func applyChatTemplate(
        messages: [[String: any Sendable]],
        tools: [[String: any Sendable]]?,
        additionalContext: [String: any Sendable]?
    ) throws -> [Int] {
        do {
            return try upstream.applyChatTemplate(messages: messages, tools: tools, additionalContext: additionalContext)
        } catch Tokenizers.TokenizerError.missingChatTemplate {
            throw MLXLMCommon.TokenizerError.missingChatTemplate
        }
    }
}
