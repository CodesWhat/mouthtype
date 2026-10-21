import Foundation
import MLX
import MLXLLM
import MLXLMCommon

/// A local instruction model run through mlx-swift-lm.
public actor MLXCleaner: MeasuredCleaner {
    public enum PromptFormat: Sendable, Equatable {
        /// The shared cleanup system prompt, with the transcript in a user turn.
        case shared
        /// Superwhisper S1-mini's native format: its fixed system prompt, a control line, thinking disabled.
        case s1Mini
    }

    public struct Spec: Sendable {
        public let id: String
        public let displayName: String
        public let repo: String
        /// Exact 40-hex Hugging Face commit this model is pinned to, never a moving ref like main.
        public let revision: String
        public let quantization: String
        public let promptFormat: PromptFormat
        public let license: String?
        /// Size of the snapshot on disk, to show before a download.
        public var downloadSizeMB: Int = 0
    }

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL?
    public nonisolated let usesSharedPrompt: Bool
    public nonisolated var usesNativeControls: Bool { spec.promptFormat == .s1Mini }
    public nonisolated let license: String?
    public nonisolated let spec: Spec

    private var container: ModelContainer?
    private let prefixCaches = PrefixCaches()
    private let downloadSource: any Downloader

    init(spec: Spec, downloadSource: any Downloader = HubDownloader()) {
        self.downloadSource = downloadSource
        self.spec = spec
        id = spec.id
        displayName = spec.displayName
        license = spec.license
        usesSharedPrompt = spec.promptFormat == .shared
        modelDirectory = HubDownloader.cacheDirectory(for: spec.repo)
    }

    public nonisolated var isDownloaded: Bool { HubDownloader.isCached(id: spec.repo, revision: spec.revision) }

    /// The commit of the cached snapshot.
    public nonisolated var revision: String? { HubDownloader.cachedRevision(id: spec.repo, revision: spec.revision) }

    public var isLoaded: Bool { container != nil }

    /// The registry configuration for the repo, with its revision set to the pinned commit.
    private var pinnedConfiguration: ModelConfiguration {
        var configuration = LLMModelFactory.shared.configuration(id: spec.repo)
        configuration.id = .id(spec.repo, revision: spec.revision)
        return configuration
    }

    /// Fetches the snapshot from Hugging Face. A partial download resumes where it stopped.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try await downloadReporting(report: { progress($0.fraction) })
    }

    /// The same download with byte progress. The Hub client's aggregate `Progress` is weighted by file size, so its units
    /// are bytes when the repo tree declared sizes and file counts when it didn't.
    public func downloadReporting(report: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        let configuration = pinnedConfiguration
        let known = Int64(spec.downloadSizeMB) * 1_000_000
        _ = try await resolve(
            configuration: configuration, from: downloadSource, useLatest: true,
            progressHandler: {
                report(ModelDownloadProgress(
                    hubCompletedUnits: $0.completedUnitCount, hubTotalUnits: $0.totalUnitCount, knownTotalBytes: known))
            })
    }

    /// After a cancelled download, deletes the partial snapshot. A complete one is left alone.
    public nonisolated func discardPartialDownload() {
        guard !isDownloaded, let directory = modelDirectory, HubDownloader.isCommitHash(spec.revision) else { return }
        HubDownloader.discardPartialSnapshot(repoDirectory: directory, commit: spec.revision)
    }

    /// Loads a downloaded snapshot into memory without touching the network.
    public func load() async throws {
        if container != nil { return }
        let downloader = HubDownloader(offline: true)
        let configuration = pinnedConfiguration
        container = try await LLMModelFactory.shared.loadContainer(
            from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
    }

    /// Drops the weights and returns MLX's buffer cache, so the memory goes back to the system.
    public func unload() {
        container = nil
        prefixCaches.clear()
        Memory.clearCache()
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        if container != nil {
            return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
        }
        let clock = ContinuousClock()
        let alreadyPresent = HubDownloader.isCached(id: spec.repo, revision: spec.revision)
        let downloader = HubDownloader()
        let configuration = pinnedConfiguration

        let downloadTime = try await clock.measure {
            _ = try await resolve(configuration: configuration, from: downloader, useLatest: false, progressHandler: { _ in })
        }
        var loaded: ModelContainer?
        let loadTime = try await clock.measure {
            loaded = try await LLMModelFactory.shared.loadContainer(
                from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
        }
        container = loaded
        return PrepareTimings(
            downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds,
            loadSeconds: loadTime.seconds,
            downloaded: !alreadyPresent
        )
    }

    public func cleanMeasured(_ transcript: String, context: CleanupContext) async throws -> CleanupResult {
        guard let container else { throw CleanerError.notPrepared(id: id) }
        // The same prompt with an empty transcript and no nearby text: where it stops matching the real prompt marks
        // the end of the part every take shares.
        var stableContext = context
        stableContext.before = nil
        stableContext.after = nil

        let clock = ContinuousClock()
        let start = clock.now
        try Task.checkCancellation()
        let input = try await container.prepare(input: promptInput(transcript, context: context))
        let stableTokens = try await container.prepare(input: promptInput("", context: stableContext)).text.tokens.asArray(Int.self)
        let prefixCaches = prefixCaches
        let (stream, generation) = try await container.perform(nonSendable: input) { model, prepared in
            try Task.checkCancellation()
            let inputTokens = model.tokenizer.encode(text: transcript, addSpecialTokens: false).count
            let parameters = GenerateParameters(
                maxTokens: CleanupLimits.maxOutputTokens(for: transcript, inputTokens: inputTokens), temperature: 0)
            let iterator = try Self.makeIterator(
                prepared: prepared, stableTokens: stableTokens, model: model.model, parameters: parameters,
                caches: prefixCaches)
            return generateTask(promptTokenCount: prepared.text.tokens.size,
                modelConfiguration: model.configuration, tokenizer: model.tokenizer, iterator: iterator,
                toolCallPolicy: parameters.toolCallPolicy)
        }

        var text = ""
        var firstOutput: Double?
        var info: GenerateCompletionInfo?
        var truncated = false
        try await withTaskCancellationHandler {
            for await event in stream {
                switch event {
                case let .chunk(chunk):
                    text += chunk
                    if firstOutput == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        firstOutput = (clock.now - start).seconds
                    }
                case let .info(completion):
                    info = completion
                    truncated = completion.stopReason == .length
                default:
                    break
                }
            }
            // Stream cancellation can finish the consumer before its producer settles GPU work.
            await generation.value
            try Task.checkCancellation()
        } onCancel: {
            generation.cancel()
        }
        let total = (clock.now - start).seconds
        let cleaned = try Self.finalize(text, input: transcript, transform: context.transform, truncated: truncated)
        return CleanupResult(
            text: cleaned,
            firstOutputSeconds: firstOutput ?? total,
            totalSeconds: total,
            outputTokens: info?.generationTokenCount,
            generationSeconds: info?.generateTime
        )
    }

    private nonisolated func promptInput(_ transcript: String, context: CleanupContext) throws -> UserInput {
        switch spec.promptFormat {
        case .shared where context.transform != nil:
            return UserInput(chat: [.system(context.transform!.systemPrompt()), .user(TextTransform.userMessage(transcript))])
        case .s1Mini where context.transform != nil:
            throw CleanerError.unavailable(reason: "\(displayName) can't run text transforms.")
        case .shared:
            return UserInput(chat: [.system(CleanupPrompt.system(for: context)), .user(CleanupPrompt.user(transcript, context: context))])
        case .s1Mini:
            return UserInput(
                chat: [.system(S1MiniPrompt.system), .user(S1MiniPrompt.user(transcript, controls: context.s1Controls))],
                additionalContext: ["enable_thinking": false])
        }
    }

    /// Fewer tokens than this aren't worth a cache of their own.
    static let minimumPrefixTokens = 16

    /// Builds the generator for a take, starting from a cached prefix when the prompt shares one. The system prompt and
    /// the dictionary text ahead of the transcript are the same every take, so their KV state is computed once and each
    /// take prefills only what comes after. A cache is only reused when its tokens are exactly the start of this
    /// prompt, so a changed dictionary, app or model just misses and builds a new one.
    static func makeIterator(
        prepared: LMInput, stableTokens: [Int], model: any LanguageModel, parameters: GenerateParameters,
        caches: PrefixCaches
    ) throws -> TokenIterator {
        guard prepared.text.mask == nil, prepared.image == nil, prepared.video == nil else {
            return try TokenIterator(input: prepared, model: model, parameters: parameters)
        }
        let tokens = prepared.text.tokens.asArray(Int.self)
        // At least one token has to be left to prefill, so the iterator has something to sample from.
        let limit = tokens.count - 1
        let stable = min(commonPrefixLength(tokens, stableTokens), limit)
        var best = caches.longestPrefix(of: tokens, upTo: limit)
        if stable >= minimumPrefixTokens, (best?.tokens.count ?? 0) < stable {
            let base = try best?.cache.map { $0.copy() } ?? model.newCache(parameters: parameters)
            let from = best?.tokens.count ?? 0
            let extra = LMInput(tokens: MLXArray(Array(tokens[from ..< stable])))
            var warm = parameters
            warm.maxTokens = 1
            // Constructing the iterator prefills `extra` into `base`.
            _ = try TokenIterator(input: extra, model: model, cache: base, parameters: warm)
            let entry = PrefixCaches.Entry(tokens: Array(tokens[0 ..< stable]), cache: base)
            caches.insert(entry)
            best = entry
        }
        guard let best else { return try TokenIterator(input: prepared, model: model, parameters: parameters) }
        let rest = LMInput(tokens: MLXArray(Array(tokens[best.tokens.count...])))
        return try TokenIterator(input: rest, model: model, cache: best.cache.map { $0.copy() }, parameters: parameters)
    }

    static func commonPrefixLength(_ a: [Int], _ b: [Int]) -> Int {
        var i = 0
        while i < a.count, i < b.count, a[i] == b[i] { i += 1 }
        return i
    }

    /// Turns raw generation into the result, or throws when the output can't be trusted. A generation that stopped at
    /// its length limit is a fragment, so dictation cleanup (which falls back to the uncleaned text on any error) and
    /// transforms (which keep Accept disabled) both refuse it.
    static func finalize(_ text: String, input: String, transform: TextTransform?, truncated: Bool) throws -> String {
        if truncated { throw CleanerError.outputTruncated }
        guard transform != nil else { return CleanupPrompt.sanitize(text) }
        let cleaned = TextTransform.sanitize(text, input: input)
        if CleanupLimits.isImplausiblyLong(output: cleaned, input: input) { throw CleanerError.outputTooLong }
        return cleaned
    }
}

public enum S1MiniPrompt {
    /// Required verbatim by the model card.
    public static let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."

    public static let controlLine = S1MiniControls.benchmark.line

    public static func user(_ transcript: String, controls: S1MiniControls = .benchmark) -> String {
        "\(controls.line)\n\(transcript)"
    }
}

/// KV caches holding the shared start of recent prompts. Touched only inside `ModelContainer.perform`, which runs one
/// generation at a time, so access is serialized.
final class PrefixCaches: @unchecked Sendable {
    struct Entry {
        let tokens: [Int]
        let cache: [KVCache]
    }

    static let capacity = 4
    private var entries: [Entry] = []

    func longestPrefix(of prompt: [Int], upTo limit: Int) -> Entry? {
        entries.filter { $0.tokens.count <= limit && prompt.starts(with: $0.tokens) }.max { $0.tokens.count < $1.tokens.count }
    }

    func insert(_ entry: Entry) {
        entries.insert(entry, at: 0)
        if entries.count > Self.capacity { entries.removeLast() }
    }

    func clear() { entries = [] }
}
