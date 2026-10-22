import Foundation

/// Ranks how likely a transcript is to be in each of a set of candidate languages. The recognizer behind it lives in the
/// platform target, so Core stays testable and Linux-neutral.
public protocol LanguageDetector: Sendable {
    /// Hypotheses restricted to `candidates`, most likely first, each with a confidence from 0 to 1.
    func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)]
}

/// Settles an Auto take's language from its transcript. Falls back to the first candidate, the primary language, when
/// the text is too short, the best guess is under the confidence threshold, or the detector names something that isn't
/// a candidate.
public struct LanguageResolver: Sendable {
    public static let defaultConfidence = 0.5
    public static let defaultMinimumWords = 3

    public var detector: (any LanguageDetector)?
    public var confidence: Double
    public var minimumWords: Int

    public init(
        detector: (any LanguageDetector)?, confidence: Double = LanguageResolver.defaultConfidence,
        minimumWords: Int = LanguageResolver.defaultMinimumWords
    ) {
        self.detector = detector
        self.confidence = confidence
        self.minimumWords = minimumWords
    }

    public func detect(_ text: String, candidates: [DictationLanguage]) -> DictationLanguage {
        let primary = candidates.first ?? .english
        guard candidates.count > 1, let detector, TextMetrics.wordCount(text) >= minimumWords else { return primary }
        guard let best = detector.hypotheses(for: text, among: candidates).first,
            candidates.contains(best.language), best.confidence >= confidence
        else { return primary }
        return best.language
    }

    /// The take's language: the request's own answer when it settles one, otherwise the detection.
    public func resolve(_ request: DictationLanguageRequest, text: String) -> DictationLanguage {
        request.resolved ?? detect(text, candidates: request.possibleLanguages)
    }
}
