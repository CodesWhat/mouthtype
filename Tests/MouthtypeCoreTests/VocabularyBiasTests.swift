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

    @Test func termCountIsCappedAtTwoHundredWithNoCharacterCap() {
        let terms = (0..<300).map { "Name\($0)" }
        let bias = VocabularyBias(terms: terms)
        #expect(bias.terms.count == VocabularyBias.maxTerms && VocabularyBias.maxTerms == 200)
        #expect(bias.terms.first == "Name0" && bias.terms.last == "Name199")
        let long = String(repeating: "x", count: 500)
        #expect(VocabularyBias(terms: [long, "Short"]).terms == [long, "Short"])
    }

    @Test func heardFormsBecomeDistinctAliasesOfTheWrittenSpelling() {
        let bias = VocabularyBias.collect(from: [
            DictionaryRule(heard: "sock guard", written: "Sockguard"),
            DictionaryRule(heard: "sockguard", written: "Sockguard"),
            DictionaryRule(heard: "Sock Guard", written: "Sockguard"),
            DictionaryRule(heard: "maya", written: "Maya"),
        ])
        #expect(bias.entries == [
            VocabularyBias.Term(text: "Sockguard", aliases: ["sock guard"]),
            VocabularyBias.Term(text: "Maya", aliases: []),
        ])
    }

    @Test func duplicatesAfterTheCapStillMergeAliases() {
        let bias = VocabularyBias(entries: [
            VocabularyBias.Term(text: "A", aliases: ["x"]), VocabularyBias.Term(text: "B"),
            VocabularyBias.Term(text: "a", aliases: ["y"]),
        ], maxTerms: 2)
        #expect(bias.entries == [VocabularyBias.Term(text: "A", aliases: ["x", "y"]), VocabularyBias.Term(text: "B")])
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
