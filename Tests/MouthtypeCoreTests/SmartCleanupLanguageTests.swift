import Foundation
import Testing

@testable import MouthtypeCore

@Suite struct SmartCleanupLanguageTests {
    private struct Stub: LanguageDetector {
        var best: DictationLanguage
        var confidence = 0.9

        func hypotheses(for text: String, among candidates: [DictationLanguage]) -> [(language: DictationLanguage, confidence: Double)] {
            [(best, confidence)]
        }
    }

    private let german = "Wir treffen uns morgen um neun Uhr im Büro und besprechen den Plan."
    private let all = Set(DictationLanguage.allCases)

    private func cleaner(native: Bool, returning output: String = "") -> FakeCleaner {
        let cleaner = FakeCleaner(returning: output)
        cleaner.usesNativeControls = native
        return cleaner
    }

    private func run(
        _ cleaner: FakeCleaner, text: String, level: CleanupLevel, language: DictationLanguage?,
        detector: (any LanguageDetector)? = nil, thorough: Set<DictationLanguage>? = nil
    ) async -> SmartCleanupResult {
        let smart = SmartCleanup(
            cleaner: cleaner, budget: { _ in .seconds(2) }, languageDetector: detector,
            thoroughLanguages: thorough ?? Set(DictationLanguage.allCases))
        return await smart.run(SmartCleanupRequest(text: text, level: level, language: language))
    }

    // MARK: Routing

    @Test func fastIsSkippedOutsideEnglishWithReasonLanguage() async {
        let fake = cleaner(native: true, returning: german)
        let result = await run(fake, text: german, level: .light, language: .german)
        #expect(result.outcome == .skipped)
        #expect(result.rejection == "language")
        #expect(result.text == german)
        #expect(fake.calls == 0)
    }

    @Test func fastStillRunsInEnglishAndForNilLanguage() async {
        for language in [nil, DictationLanguage.english] {
            let fake = cleaner(native: true, returning: "We meet at nine in the office.")
            let result = await run(fake, text: "we meet at nine in the office", level: .light, language: language)
            #expect(result.outcome == .ok)
            #expect(fake.calls == 1)
        }
    }

    @Test func thoroughRunsOutsideEnglishWhenTheLanguageIsSupported() async {
        let fake = cleaner(native: false, returning: german)
        let result = await run(fake, text: german, level: .medium, language: .german)
        #expect(result.outcome == .ok)
        #expect(fake.calls == 1)
        #expect(fake.contexts.first?.language == .german)
    }

    @Test func thoroughIsSkippedForALanguageOutsideTheSupportedSet() async {
        let fake = cleaner(native: false, returning: german)
        let result = await run(fake, text: german, level: .medium, language: .german, thorough: [.french])
        #expect(result.outcome == .skipped)
        #expect(result.rejection == SmartLanguageSupport.skipReason)
        #expect(fake.calls == 0)
    }

    @Test func englishNeverDependsOnTheSupportedSet() async {
        let fake = cleaner(native: false, returning: "We meet at nine in the office.")
        let result = await run(fake, text: "we meet at nine in the office", level: .medium, language: .english, thorough: [])
        #expect(result.outcome == .ok)
    }

    @Test func nonEnglishTakesSkipTheEnglishCorrectionPass() async {
        let said = "Wir treffen uns um drei, sorry, um vier Uhr im Büro heute"
        let fake = cleaner(native: false, returning: said)
        _ = await run(fake, text: said, level: .medium, language: .german)
        #expect(fake.calls == 1)
        #expect(fake.contexts.allSatisfy { !$0.correctionsOnly })
    }

    // MARK: Guard

    @Test func aTranslationToEnglishIsRejectedByTheLanguageCheck() async {
        let translated = "We are meeting tomorrow at nine o'clock in the office and discussing the plan."
        let fake = cleaner(native: false, returning: translated)
        let result = await run(fake, text: german, level: .medium, language: .german, detector: Stub(best: .english))
        #expect(result.outcome == .guardRejected)
        #expect(result.rejection?.contains("English") == true)
        #expect(result.text == german)
    }

    @Test func aTranslationThatKeepsMostWordsIsStillRejectedByTheLanguageCheck() {
        let reason = SmartCleanupGuard.languageChange(
            output: "We meet tomorrow um neun Uhr in the office", language: .german, detector: Stub(best: .english))
        #expect(reason != nil)
    }

    @Test func aCleanupInTheSameLanguagePassesTheLanguageCheck() async {
        let cleaned = "Wir treffen uns morgen um 9 Uhr im Büro und besprechen den Plan."
        let fake = cleaner(native: false, returning: cleaned)
        let result = await run(fake, text: german, level: .medium, language: .german, detector: Stub(best: .german))
        #expect(result.outcome == .ok)
        #expect(result.text == cleaned)
    }

    @Test func aLowConfidenceEnglishGuessDoesNotRejectOrCheckShortText() {
        #expect(
            SmartCleanupGuard.languageChange(output: german, language: .german, detector: Stub(best: .english, confidence: 0.4)) == nil)
        #expect(SmartCleanupGuard.languageChange(output: "Guten Tag", language: .german, detector: Stub(best: .english)) == nil)
        #expect(SmartCleanupGuard.languageChange(output: german, language: .german, detector: nil) == nil)
        #expect(SmartCleanupGuard.languageChange(output: german, language: .english, detector: Stub(best: .german)) == nil)
        #expect(SmartCleanupGuard.languageChange(output: german, language: nil, detector: Stub(best: .german)) == nil)
    }

    @Test func englishOnlyChecksDoNotFireOutsideEnglish() {
        // "no" is the Spanish negation, and a repeated one is just emphasis. The English negation count must not apply.
        let input = "No, no puedo ir hoy a la oficina con ustedes."
        let output = "No puedo ir hoy a la oficina con ustedes."
        #expect(SmartCleanupGuard.rejection(input: input, output: output, level: .medium) != nil)
        #expect(SmartCleanupGuard.rejection(input: input, output: output, level: .medium, language: .spanish) == nil)
    }

    @Test func germanNounsAreNotTreatedAsNames() {
        let input = "Wir haben gestern einen Hund und eine Katze gekauft."
        let output = "Wir haben gestern einen hund und eine Katze gekauft."
        #expect(SmartCleanupGuard.missingName(input: input, output: output) == "Hund")
        #expect(SmartCleanupGuard.rejection(input: input, output: output, level: .medium, language: .german) == nil)
        #expect(SmartCleanupGuard.rejection(input: input, output: output, level: .medium, language: .french) != nil)
    }

    @Test func digitsMustSurviveOutsideEnglish() {
        let input = "Das Treffen ist um 15 Uhr in Raum 204 im Haus."
        #expect(
            SmartCleanupGuard.rejection(input: input, output: "Das Treffen ist um 15 Uhr in Raum 205 im Haus.", level: .medium, language: .german)
                != nil)
        #expect(
            SmartCleanupGuard.rejection(input: input, output: input, level: .medium, language: .german) == nil)
    }

    @Test func numberWordsThatAreNotEnglishAreNotMistakenForNumbers() {
        // Polish "ten" is "this", not 10. Dropping it is fine for the neutral checks only when other words carry the text.
        let input = "Ten dom jest bardzo duży i stary."
        let output = "Dom jest bardzo duży i stary."
        #expect(SmartCleanupGuard.rejection(input: input, output: output, level: .medium, language: .polish) == nil)
    }

    // MARK: Prompt

    @Test func theNonEnglishPromptCarriesTheLanguageLineLastAndNoEnglishOnlyRules() {
        let prompt = CleanupPrompt.system(
            for: CleanupContext(
                vocabulary: ["Mouthtype"], appName: "Notes", level: .medium, omitProfanity: true, language: .german))
        #expect(prompt.hasSuffix("The transcript is in German. Keep it in German. Never translate it."))
        #expect(!prompt.contains("$25"))
        #expect(!prompt.contains("3:30 PM"))
        #expect(!prompt.contains("um, uh, er"))
        #expect(!prompt.contains("Tuesday"))
        #expect(!prompt.contains("U S B"))
        #expect(!prompt.contains("leave out swearing"))
        #expect(prompt.contains("Never translate."))
        #expect(prompt.contains("Mouthtype"))
    }

    @Test func theLanguageLineNamesEachLanguage() {
        #expect(CleanupPrompt.languageLine(.russian).contains("Russian"))
        #expect(CleanupPrompt.languageLine(.portuguese).contains("Portuguese"))
    }

    @Test func englishAndNilKeepTheEnglishPromptUnchanged() {
        #expect(CleanupPrompt.system(for: CleanupContext(language: .english)) == CleanupPrompt.systemPrompt)
        #expect(CleanupPrompt.system(for: CleanupContext()) == CleanupPrompt.systemPrompt)
    }

    @Test func theNonEnglishPromptsShareEverythingBeforeTheLanguageLine() {
        let german = CleanupPrompt.system(for: CleanupContext(vocabulary: ["Mouthtype"], language: .german))
        let french = CleanupPrompt.system(for: CleanupContext(vocabulary: ["Mouthtype"], language: .french))
        let shared = german.dropLast(CleanupPrompt.languageLine(.german).count)
        #expect(french.hasPrefix(String(shared)))
    }

    @Test func differentLanguagesGiveDifferentPromptHashes() async {
        let said = german
        let one = cleaner(native: false, returning: said)
        let two = cleaner(native: false, returning: said)
        let a = await run(one, text: said, level: .medium, language: .german)
        let b = await run(two, text: said, level: .medium, language: .french)
        #expect(a.promptSHA != nil && a.promptSHA != b.promptSHA)
    }

    // MARK: Transform and budget

    @Test func everyTransformAsksForTheSameLanguage() {
        for transform in TextTransform.allCases {
            #expect(transform.systemPrompt().contains("Reply in the same language as the text."))
        }
    }

    @Test func theBudgetMultiplierIsOneForEnglishAndNeverBelowOne() {
        #expect(SmartLanguageSupport.budgetMultiplier(for: nil) == 1)
        #expect(SmartLanguageSupport.budgetMultiplier(for: .english) == 1)
        for language in DictationLanguage.allCases { #expect(SmartLanguageSupport.budgetMultiplier(for: language) >= 1) }
    }

    @Test func measuredLanguagesGetTheirMultiplier() {
        #expect(SmartLanguageSupport.budgetMultiplier(for: .polish) == 1.5)
        #expect(SmartLanguageSupport.budgetMultiplier(for: .russian) == 1.25)
        #expect(SmartLanguageSupport.budgetMultiplier(for: .german) == 1)
    }

    @Test func theSupportedSetIsTheGatedTierOneLanguages() {
        #expect(SmartLanguageSupport.thoroughLanguages == [.german, .spanish, .french, .italian, .portuguese, .dutch, .polish, .russian])
        #expect(!SmartLanguageSupport.supports(level: .light, language: .german, thorough: SmartLanguageSupport.thoroughLanguages))
        #expect(SmartLanguageSupport.supports(level: .medium, language: .german))
        #expect(!SmartLanguageSupport.supports(level: .medium, language: .greek))
        #expect(SmartLanguageSupport.supports(level: .light, language: nil))
    }

    @Test func theLanguageMultiplierScalesTheWordsTheBudgetSees() async {
        let words = TextMetrics.wordCount(german)
        let seen = BudgetSpy()
        let fake = cleaner(native: false, returning: german)
        let smart = SmartCleanup(
            cleaner: fake,
            budget: {
                seen.record($0); return .seconds(2)
            }, thoroughLanguages: all)
        _ = await smart.run(SmartCleanupRequest(text: german, level: .medium, language: .german))
        _ = await smart.run(SmartCleanupRequest(text: german, level: .medium, language: nil))
        let multiplier = SmartLanguageSupport.budgetMultiplier(for: .german)
        #expect(seen.values == [Int((Double(words) * multiplier).rounded(.up)), words])
        _ = await smart.run(SmartCleanupRequest(text: german, level: .medium, language: .polish))
        #expect(seen.values.last == Int((Double(words) * 1.5).rounded(.up)))
    }
}

private final class BudgetSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []
    func record(_ value: Int) { lock.withLock { recorded.append(value) } }
    var values: [Int] { lock.withLock { recorded } }
}
