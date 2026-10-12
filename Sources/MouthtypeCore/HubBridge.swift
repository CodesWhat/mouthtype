import Foundation
import HuggingFace
import MLXLMCommon
import Tokenizers
import os

/// Downloads model snapshots from the Hugging Face Hub, and serves a complete cached snapshot without touching the network.
struct HubDownloader: MLXLMCommon.Downloader {
    private let client = HubClient()

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
        if !useLatest, let snapshot = Self.completeSnapshot(repo: repo, ref: ref) {
            return snapshot
        }
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
        guard fm.fileExists(atPath: snapshot.appendingPathComponent("config.json").path) else { return nil }
        let indexURL = snapshot.appendingPathComponent("model.safetensors.index.json")
        if let data = try? Data(contentsOf: indexURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let weightMap = json["weight_map"] as? [String: String] {
            return Set(weightMap.values).allSatisfy { fm.fileExists(atPath: snapshot.appendingPathComponent($0).path) } ? snapshot : nil
        }
        let files = (try? fm.contentsOfDirectory(atPath: snapshot.path)) ?? []
        return files.contains { $0.hasSuffix(".safetensors") } ? snapshot : nil
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
