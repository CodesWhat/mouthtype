import FluidAudio
import Foundation
import Testing

@testable import MouthtypeCore

@Suite struct DictationLanguageRequestTests {
    @Test func parakeetHintMatrix() {
        // English, a single Auto candidate and Latin-only sets keep the 0.5.0 hint.
        #expect(DictationLanguageRequest.english.parakeetHint == .english)
        #expect(DictationLanguageRequest.auto(candidates: [.english]).parakeetHint == .english)
        #expect(DictationLanguageRequest.auto(candidates: []).parakeetHint == .english)
        #expect(DictationLanguageRequest.auto(candidates: [.english, .german, .spanish]).parakeetHint == .english)
        #expect(DictationLanguageRequest.explicit(.german).parakeetHint == .english)
        // French must never be sent: its hint adds an English-word blocklist.
        #expect(DictationLanguageRequest.explicit(.french).parakeetHint == .english)
        #expect(DictationLanguageRequest.auto(candidates: [.english, .french]).parakeetHint == .english)
        // Cyrillic and Greek need no hint at all.
        for language in [DictationLanguage.russian, .ukrainian, .bulgarian, .greek] {
            #expect(DictationLanguageRequest.explicit(language).parakeetHint == nil)
            #expect(DictationLanguageRequest.auto(candidates: [.english, language]).parakeetHint == nil)
        }
    }

    @Test func everyExplicitLanguageGetsEnglishOrNoHint() {
        for language in DictationLanguage.allCases {
            let hint = DictationLanguageRequest.explicit(language).parakeetHint
            #expect(hint == .english || hint == nil)
        }
    }

    @Test func resolvedLanguage() {
        #expect(DictationLanguageRequest.explicit(.polish).resolved == .polish)
        #expect(DictationLanguageRequest.auto(candidates: [.german]).resolved == .german)
        #expect(DictationLanguageRequest.auto(candidates: []).resolved == .english)
        #expect(DictationLanguageRequest.auto(candidates: [.english, .german]).resolved == nil)
    }

    @Test func whisperUsesTheResolvedLanguageOrDetects() {
        #expect(DictationLanguageRequest.english.whisperLanguage == "en")
        #expect(DictationLanguageRequest.explicit(.german).whisperLanguage == "de")
        #expect(DictationLanguageRequest.auto(candidates: [.english, .german]).whisperLanguage == nil)
        let detecting = WhisperEngine.decodingOptions(promptTokens: nil, language: nil)
        #expect(detecting.language == nil && detecting.detectLanguage)
        let german = WhisperEngine.decodingOptions(promptTokens: nil, language: "de")
        #expect(german.language == "de" && !german.detectLanguage)
        #expect(WhisperEngine.decodingOptions(promptTokens: nil).language == "en")
    }

    @Test func theEnglishOnlyWhisperModelAlwaysDecodesEnglish() {
        let german = DictationLanguageRequest.explicit(.german)
        #expect(WhisperEngine.decodingLanguage(variant: WhisperEngine.smallEnVariant, request: german) == "en")
        #expect(WhisperEngine.decodingLanguage(variant: WhisperEngine.turboVariant, request: german) == "de")
    }

    @Test func boostNeedsEnglishToBePossible() {
        #expect(DictationLanguageRequest.english.allowsVocabularyBoost)
        #expect(DictationLanguageRequest.auto(candidates: [.english, .german]).allowsVocabularyBoost)
        #expect(!DictationLanguageRequest.explicit(.german).allowsVocabularyBoost)
        #expect(!DictationLanguageRequest.auto(candidates: [.german, .french]).allowsVocabularyBoost)
    }
}
