import Foundation
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
    }

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL?
    public nonisolated let usesSharedPrompt: Bool
    public nonisolated let license: String?
    public nonisolated let spec: Spec

    private var container: ModelContainer?

    init(spec: Spec) {
        self.spec = spec
        id = spec.id
        displayName = spec.displayName
        license = spec.license
        usesSharedPrompt = spec.promptFormat == .shared
        modelDirectory = HubDownloader.cacheDirectory(for: spec.repo)
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
        case .shared:
            messages = [.system(CleanupPrompt.system(for: context)), .user(CleanupPrompt.user(transcript))]
        case .s1Mini:
            messages = [.system(S1MiniPrompt.system), .user(S1MiniPrompt.user(transcript))]
            additionalContext = ["enable_thinking": false]
        }
        let parameters = GenerateParameters(maxTokens: CleanupLimits.maxOutputTokens(for: transcript), temperature: 0)

        let clock = ContinuousClock()
        let start = clock.now
        let input = try await container.prepare(input: UserInput(chat: messages, additionalContext: additionalContext))
        let stream = try await container.generate(input: input, parameters: parameters)

        var text = ""
        var firstOutput: Double?
        var info: GenerateCompletionInfo?
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
        let total = (clock.now - start).seconds
        return CleanupResult(
            text: CleanupPrompt.sanitize(text),
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

    public static let controlLine = "[Styling: semi-formal] [Structure: lists] [Context: general]"

    public static func user(_ transcript: String) -> String {
        "\(controlLine)\n\(transcript)"
    }
}
