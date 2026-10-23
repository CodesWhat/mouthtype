import Foundation
import MouthtypeCore
import NaturalLanguage

/// `NLLanguageRecognizer` constrained to the candidate set, which it handles far better than all 25 languages.
struct NLLanguageDetector: LanguageDetector {
    func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)] {
        guard !candidates.isEmpty else { return [] }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = candidates.map { NLLanguage(rawValue: $0.code) }
        recognizer.processString(text)
        return recognizer.languageHypotheses(withMaximum: candidates.count)
            .compactMap { entry in DictationLanguage(code: entry.key.rawValue).map { ($0, entry.value) } }
            .sorted { $0.1 > $1.1 }
    }
}
