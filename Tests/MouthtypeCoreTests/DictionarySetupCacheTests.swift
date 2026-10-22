import Testing
@testable import MouthtypeCore

@Suite struct DictionarySetupCacheTests {
    @Test func editingARuleChangesTheReplacement() {
        var rules = [DictionaryRule(heard: "cache probe alpha", written: "Alpha")]
        #expect(DictionaryReplacer(rules: rules).apply(to: "say cache probe alpha now") == "say Alpha now")
        rules[0].written = "ALPHA"
        #expect(DictionaryReplacer(rules: rules).apply(to: "say cache probe alpha now") == "say ALPHA now")
        rules[0].heard = "cache probe beta"
        #expect(DictionaryReplacer(rules: rules).apply(to: "say cache probe alpha now") == "say cache probe alpha now")
        #expect(DictionaryReplacer(rules: rules).apply(to: "say cache probe beta now") == "say ALPHA now")
    }

    @Test func addingAndRemovingRulesInvalidates() {
        let one = [DictionaryRule(heard: "cache probe gamma", written: "Gamma")]
        let two = one + [DictionaryRule(heard: "cache probe delta", written: "Delta")]
        #expect(DictionaryReplacer(rules: one).apply(to: "cache probe delta") == "cache probe delta")
        #expect(DictionaryReplacer(rules: two).apply(to: "cache probe delta") == "Delta")
        #expect(DictionaryReplacer(rules: one).apply(to: "cache probe delta") == "cache probe delta")
        #expect(DictionaryReplacer(rules: []).apply(to: "cache probe gamma") == "cache probe gamma")
    }

    @Test func vocabularyBiasFollowsEdits() {
        var rules = [DictionaryRule(heard: "cache probe eps", written: "Epsilon")]
        #expect(VocabularyBias.collect(from: rules).terms == ["Epsilon"])
        rules[0].written = "Eps2"
        #expect(VocabularyBias.collect(from: rules).terms == ["Eps2"])
        rules[0].starred = true
        rules.append(DictionaryRule(heard: "cache probe zeta", written: "Zeta", starred: true))
        #expect(VocabularyBias.collect(from: rules).terms == ["Eps2", "Zeta"])
        rules.swapAt(0, 1)
        #expect(VocabularyBias.collect(from: rules).terms == ["Zeta", "Eps2"])
    }

    @Test func cleanupVocabularyAndAliasChecksFollowEdits() {
        var rules = [DictionaryRule(heard: "cache probe eta", written: "Eta")]
        #expect(DictionaryReplacer(rules: rules).cleanupVocabulary().isEmpty)
        #expect(DictionaryReplacer.introducedAlias(input: "hello", output: "Eta", rules: rules) == "Eta")
        rules[0] = DictionaryRule(heard: "eta", written: "Eta")
        #expect(DictionaryReplacer(rules: rules).cleanupVocabulary() == ["Eta"])
        #expect(DictionaryReplacer.introducedAlias(input: "hello", output: "Eta", rules: rules) == nil)
        rules[0] = DictionaryRule(heard: "cache probe eta", written: "Eta")
        #expect(DictionaryReplacer.introducedAlias(input: "cache probe eta", output: "Eta", rules: rules) == nil)
        #expect(DictionaryReplacer.introducedAlias(input: "hello", output: "Eta", rules: rules) == "Eta")
    }

    @Test func ordinaryWordsHandlesNonAsciiAndPunctuation() {
        #expect(OrdinaryWords.isOrdinary("don\u{2019}t"))
        #expect(OrdinaryWords.isOrdinary("The Cat"))
        #expect(!OrdinaryWords.isOrdinary("win32"))
        #expect(!OrdinaryWords.isOrdinary("node.js"))
        #expect(!OrdinaryWords.isOrdinary("caf\u{00E9}"))
        #expect(!OrdinaryWords.isOrdinary("\u{00E9}\u{00E9}"))
    }
}
