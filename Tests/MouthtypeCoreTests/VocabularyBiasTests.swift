import Testing
import WhisperKit
@testable import MouthtypeCore

@Suite struct VocabularyBiasTests {
    @Test func collectPutsStarredFirstAndUsesWrittenForm() {
        let bias = VocabularyBias.collect(from: [
            DictionaryRule(heard: "sock guard", written: "Sockguard"),
            DictionaryRule(heard: "drydock", written: "Drydock", starred: true),
            DictionaryRule(heard: "", written: "Ignored"),
        ])
        #expect(bias.terms == ["Drydock", "Sockguard"])
        #expect(bias.promptText == "Drydock, Sockguard")
    }

    @Test func duplicatesAndBlanksAreDropped() {
        let bias = VocabularyBias(terms: ["Maya", "  ", "maya", " Ana   Lopez ", ""])
        #expect(bias.terms == ["Maya", "Ana Lopez"])
    }

    @Test func termCountIsCapped() {
        let terms = (0..<200).map { "Name\($0)" }
        #expect(VocabularyBias(terms: terms).terms.count == VocabularyBias.maxTerms)
        #expect(VocabularyBias(terms: terms).terms.first == "Name0")
    }

    @Test func characterBudgetIsCappedAndNeverCutsATermShort() {
        let bias = VocabularyBias(terms: ["aaaa", "bbbb", "cccc"], maxTerms: 10, maxCharacters: 10)
        #expect(bias.terms == ["aaaa", "bbbb"])
        #expect(bias.promptText.count <= 10)
        let long = VocabularyBias(terms: [String(repeating: "x", count: 500), "Short"])
        #expect(long.terms == ["Short"])
    }

    @Test func emptyBiasProducesNoPrompt() {
        #expect(WhisperEngine.promptTokens(for: nil, encode: { _ in [1] }, firstSpecialToken: 100) == nil)
        #expect(WhisperEngine.promptTokens(for: VocabularyBias(terms: []), encode: { _ in [1] }, firstSpecialToken: 100) == nil)
        #expect(WhisperEngine.decodingOptions(promptTokens: nil).promptTokens == nil)
    }

    @Test func promptCarriesTheTermsWithoutSpecialTokensAndStaysUnderTheBudget() {
        var encoded: [String] = []
        let tokens = WhisperEngine.promptTokens(
            for: VocabularyBias(terms: ["Maya", "Drydock"]),
            encode: { text in encoded.append(text); return [5, 6, 500, 7] },
            firstSpecialToken: 100
        )
        #expect(encoded == [" Maya, Drydock"])
        #expect(tokens == [5, 6, 7])
        let many = WhisperEngine.promptTokens(
            for: VocabularyBias(terms: ["Maya"]), encode: { _ in Array(0..<500) }, firstSpecialToken: 1000
        )
        #expect(many?.count == WhisperEngine.maxPromptTokens)
    }

    @Test func decodingRequestCarriesThePromptWhenOnAndNotWhenOff() {
        #expect(WhisperEngine.decodingOptions(promptTokens: [5, 6]).promptTokens == [5, 6])
        #expect(WhisperEngine.decodingOptions(promptTokens: nil).promptTokens == nil)
    }
}
