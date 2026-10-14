import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

/// Apple's on-device foundation model through the FoundationModels framework. Needs no download on macOS 26 or later.
public final class AppleCleaner: MeasuredCleaner {
    public static let modelID = "apple-foundation-model"
    public static let modelDisplayName = "Apple on-device model (FoundationModels)"

    public let id = AppleCleaner.modelID
    public let displayName = AppleCleaner.modelDisplayName
    public let modelDirectory: URL? = nil

    init() {}

    public func prepareMeasured() async throws -> PrepareTimings {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return PrepareTimings(downloadSeconds: 0, loadSeconds: 0, downloaded: false)
            case let .unavailable(reason):
                throw CleanerError.unavailable(reason: Self.describe(reason))
            }
        }
        #endif
        throw CleanerError.unavailable(reason: "Requires macOS 26 or later")
    }

    public func cleanMeasured(_ transcript: String, context: CleanupContext) async throws -> CleanupResult {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            let session = LanguageModelSession(instructions: CleanupPrompt.system(for: context))
            let options = GenerationOptions(
                samplingMode: .greedy, maximumResponseTokens: CleanupLimits.maxOutputTokens(for: transcript))
            let clock = ContinuousClock()
            let start = clock.now
            var text = ""
            var firstOutput: Double?
            for try await snapshot in session.streamResponse(to: CleanupPrompt.user(transcript, context: context), options: options) {
                text = snapshot.content
                if firstOutput == nil, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    firstOutput = (clock.now - start).seconds
                }
            }
            let total = (clock.now - start).seconds
            return CleanupResult(text: CleanupPrompt.sanitize(text), firstOutputSeconds: firstOutput ?? total, totalSeconds: total)
        }
        #endif
        throw CleanerError.unavailable(reason: "Requires macOS 26 or later")
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private static func describe(_ reason: SystemLanguageModel.Availability.UnavailableReason) -> String {
        switch reason {
        case .deviceNotEligible: return "Unavailable: this device is not eligible for Apple Intelligence"
        case .appleIntelligenceNotEnabled: return "Unavailable: Apple Intelligence is turned off"
        case .modelNotReady: return "Unavailable: the on-device model is not downloaded yet"
        @unknown default: return "Unavailable: unknown reason"
        }
    }
    #endif
}
