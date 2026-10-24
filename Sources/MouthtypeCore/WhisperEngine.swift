import Foundation
import WhisperKit

public actor WhisperEngine: MeasuredTranscriber, VocabularyBiasing {
    public static let turboID = "whisper-large-v3-turbo"
    static let turboDisplayName = "Whisper large-v3 turbo"
    static let turboVariant = "large-v3-v20240930_turbo"
    static let smallEnID = "whisper-small-en"
    static let smallEnDisplayName = "Whisper small.en"
    static let smallEnVariant = "small.en"

    private static let modelRepo = ModelPins.whisperKit.repo

    public nonisolated let id: String
    public nonisolated let displayName: String
    public nonisolated let modelDirectory: URL

    private let variant: String
    private var kit: WhisperKit?
    private var bias: VocabularyBias?

    init(id: String, displayName: String, variant: String) {
        self.id = id
        self.displayName = displayName
        self.variant = variant
        modelDirectory = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("huggingface/models/\(Self.modelRepo)/openai_whisper-\(variant)", isDirectory: true)
    }

    public func prepare() async throws {
        _ = try await prepareMeasured()
    }

    public func prepareMeasured() async throws -> PrepareTimings {
        if kit != nil {
            return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
        }
        let clock = ContinuousClock()
        let alreadyPresent = FileManager.default.fileExists(atPath: modelDirectory.appendingPathComponent("AudioEncoder.mlmodelc").path)

        var folder = modelDirectory
        let downloadTime = try await clock.measure {
            folder = try await WhisperModelFetch.download(variant: variant)
        }
        var loaded: WhisperKit?
        let loadTime = try await clock.measure {
            let config = WhisperKitConfig(
                modelFolder: folder.path,
                verbose: false,
                logLevel: .none,
                load: true,
                download: false
            )
            loaded = try await WhisperKit(config)
        }
        kit = loaded
        return PrepareTimings(
            downloadSeconds: alreadyPresent ? 0 : downloadTime.seconds,
            loadSeconds: loadTime.seconds,
            downloaded: !alreadyPresent
        )
    }

    public func setVocabularyBias(_ bias: VocabularyBias?) {
        self.bias = bias?.isEmpty == false ? bias : nil
    }

    /// Whisper's prompt budget is half its 448-token context. Stay well under it so the audio keeps its room.
    static let maxPromptTokens = 96

    /// The prompt for `bias`, encoded without special tokens and cut to the budget. Nil when there is nothing to send.
    static func promptTokens(for bias: VocabularyBias?, encode: (String) -> [Int], firstSpecialToken: Int) -> [Int]? {
        guard let bias, !bias.isEmpty else { return nil }
        let tokens = encode(" " + bias.promptText).filter { $0 < firstSpecialToken }
        return tokens.isEmpty ? nil : Array(tokens.prefix(maxPromptTokens))
    }

    /// `language` is the code to decode in, or nil to let Whisper detect it. Forcing "en" on other speech translates it or
    /// returns nothing.
    static func decodingOptions(promptTokens: [Int]?, language: String? = "en") -> DecodingOptions {
        DecodingOptions(
            verbose: false, task: .transcribe, language: language, detectLanguage: language == nil,
            wordTimestamps: true, promptTokens: promptTokens
        )
    }

    static func transcriptionLanguage(variant: String, request: DictationLanguageRequest, detectedCode: String?) -> DictationLanguage? {
        if variant == smallEnVariant { return .english }
        if let resolved = request.resolved { return resolved }
        guard let detectedCode, let detected = DictationLanguage(code: detectedCode), request.possibleLanguages.contains(detected) else { return nil }
        return detected
    }

    public func transcribe(samples: [Float]) async throws -> Transcription {
        try await transcribe(samples: samples, language: .english)
    }

    /// The English-only variant always decodes in English. The multilingual one uses the resolved language, or detects it.
    static func decodingLanguage(variant: String, request: DictationLanguageRequest) -> String? {
        variant.hasSuffix(".en") ? "en" : request.whisperLanguage
    }

    public func transcribe(samples: [Float], language request: DictationLanguageRequest) async throws -> Transcription {
        guard let kit else { throw EngineError.notPrepared(id: id) }
        var tokens: [Int]?
        if request.allowsVocabularyBoost, let tokenizer = kit.tokenizer {
            tokens = Self.promptTokens(
                for: bias, encode: { tokenizer.encode(text: $0) }, firstSpecialToken: tokenizer.specialTokens.specialTokenBegin
            )
        }
        let options = Self.decodingOptions(promptTokens: tokens, language: Self.decodingLanguage(variant: variant, request: request))
        let clock = ContinuousClock()
        let start = clock.now
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options)
        let elapsed = (clock.now - start).seconds
        let words = results.flatMap(\.segments).flatMap { $0.words ?? [] }.map {
            WordTiming(
                word: $0.word.trimmingCharacters(in: .whitespaces),
                start: Double($0.start), end: Double($0.end), confidence: $0.probability
            )
        }
        return Transcription(
            text: results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines),
            words: words,
            confidence: nil,
            processingSeconds: elapsed,
            engineID: id,
            modelRevision: "\(Self.modelRepo)/openai_whisper-\(variant)",
            language: Self.transcriptionLanguage(variant: variant, request: request, detectedCode: results.first?.language)
        )
    }
}
