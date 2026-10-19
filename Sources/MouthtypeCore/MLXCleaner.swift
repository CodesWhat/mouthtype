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

    public nonisolated var isDownloaded: Bool { HubDownloader.isCached(id: spec.repo) }

    /// The commit of the cached snapshot.
    public nonisolated var revision: String? { HubDownloader.cachedRevision(id: spec.repo) }

    public var isLoaded: Bool { container != nil }

    /// Fetches the snapshot from Hugging Face. A partial download resumes where it stopped.
    public func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        let configuration = LLMModelFactory.shared.configuration(id: spec.repo)
        _ = try await resolve(
            configuration: configuration, from: downloadSource, useLatest: true,
            progressHandler: { progress($0.fractionCompleted) })
    }

    /// Loads a downloaded snapshot into memory without touching the network.
    public func load() async throws {
        if container != nil { return }
        let downloader = HubDownloader(offline: true)
        let configuration = LLMModelFactory.shared.configuration(id: spec.repo)
        container = try await LLMModelFactory.shared.loadContainer(
            from: downloader, using: TransformersTokenizerLoader(), configuration: configuration)
    }

    /// Drops the weights and returns MLX's buffer cache, so the memory goes back to the system.
    public func unload() {
        container = nil
        Memory.clearCache()
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        if container != nil {
            return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
        }
        let clock = ContinuousClock()
        let alreadyPresent = HubDownloader.isCached(id: spec.repo)
        let downloader = HubDownloader()
        let configuration = LLMModelFactory.shared.configuration(id: spec.repo)

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
        let messages: [Chat.Message]
        var additionalContext: [String: any Sendable]?
        switch spec.promptFormat {
        case .shared where context.transform != nil:
            messages = [.system(context.transform!.systemPrompt()), .user(TextTransform.userMessage(transcript))]
        case .s1Mini where context.transform != nil:
            throw CleanerError.unavailable(reason: "\(displayName) can't run text transforms.")
        case .shared:
            messages = [.system(CleanupPrompt.system(for: context)), .user(CleanupPrompt.user(transcript, context: context))]
        case .s1Mini:
            messages = [.system(S1MiniPrompt.system), .user(S1MiniPrompt.user(transcript, controls: context.s1Controls))]
            additionalContext = ["enable_thinking": false]
        }
        let parameters = GenerateParameters(maxTokens: CleanupLimits.maxOutputTokens(for: transcript), temperature: 0)

        let clock = ContinuousClock()
        let start = clock.now
        try Task.checkCancellation()
        let input = try await container.prepare(input: UserInput(chat: messages, additionalContext: additionalContext))
        let (stream, generation) = try await container.perform(nonSendable: input) { model, prepared in
            try Task.checkCancellation()
            let iterator = try TokenIterator(input: prepared, model: model.model, parameters: parameters)
            return generateTask(promptTokenCount: prepared.text.tokens.size,
                modelConfiguration: model.configuration, tokenizer: model.tokenizer, iterator: iterator,
                toolCallPolicy: parameters.toolCallPolicy)
        }

        var text = ""
        var firstOutput: Double?
        var info: GenerateCompletionInfo?
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
        return CleanupResult(
            text: context.transform == nil ? CleanupPrompt.sanitize(text) : TextTransform.sanitize(text),
            firstOutputSeconds: firstOutput ?? total,
            totalSeconds: total,
            outputTokens: info?.generationTokenCount,
            generationSeconds: info?.generateTime
        )
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
