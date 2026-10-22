import Testing
@testable import MouthtypeCore

@Suite struct CorrectionLearnerTests {
    private func pairs(_ pasted: String, _ field: String) -> [String] {
        CorrectionLearner.proposals(pasted: pasted, field: field).map { "\($0.heard)>\($0.corrected)" }
    }

    private let sentence = "Hove said the new build is ready for review today"

    @Test(
        arguments: [
            ("Hove said the new build is ready for review today", "Hov said the new build is ready for review today", ["Hove>Hov"]),
            ("Ask praya to send the notes before lunch tomorrow", "Ask Priya to send the notes before lunch tomorrow", ["praya>Priya"]),
            ("Open mouth type and start the new dictation now", "Open Mouthtype and start the new dictation now", ["mouth type>Mouthtype"]),
            ("We moved to dry dock for the deploys this week", "We moved to Drydock for the deploys this week", ["dry dock>Drydock"]),
            ("Ask the prayer to send the notes before lunch", "Ask the Priya to send the notes before lunch", ["prayer>Priya"]),
            ("Tell there that the lunch is ready now", "Tell Thayer that the lunch is ready now", ["there>Thayer"]),
            ("Send it to zoe about the new schedule tomorrow", "Send it to Zoë about the new schedule tomorrow", ["zoe>Zoë"]),
            ("Ask shunade to join the call this afternoon", "Ask Sinead to join the call this afternoon", ["shunade>Sinead"]),
        ] as [(String, String, [String])])
    func vocabularyFixesAreProposed(pasted: String, field: String, expected: [String]) {
        #expect(pairs(pasted, field) == expected)
    }

    @Test func anOversizedWordIsSkippedQuickly() {
        let huge = String(repeating: "a", count: 100_000)
        let start = ContinuousClock.now
        #expect(pairs("alpha \(huge) omega", "alpha \(huge)b omega").isEmpty)
        #expect(!CorrectionLearner.similar(huge, huge + "b"))
        if TextTestSupport.timingAssertsEnabled { #expect(ContinuousClock.now - start < .seconds(2)) }
    }

    @Test func textTypedBeforeAndAfterTheSpanIsSkipped() {
        let field = "Hi team, quick note. Hov said the new build is ready for review today. Thanks, Sam"
        #expect(pairs(sentence, field) == ["Hove>Hov"])
    }

    @Test func aLeadingSpaceAndSurroundingPunctuationDontMatter() {
        #expect(pairs(" " + sentence + ".", "\n(Hov said the new build is ready for review today)") == ["Hove>Hov"])
    }

    @Test func twoFixesInOneDictationAreBothProposed() {
        let pasted = "Hove asked praya to review the plan before the standup"
        let field = "Hov asked Priya to review the plan before the standup"
        #expect(pairs(pasted, field) == ["Hove>Hov", "praya>Priya"])
    }

    @Test func aFixAtEitherEdgeStaysInsideTheSpan() {
        #expect(pairs("Ship the build to hove", "Ship the build to Hov") == ["hove>Hov"])
        #expect(pairs(sentence, "before Hov said the new build is ready for review today after") == ["Hove>Hov"])
    }

    @Test func theDictationAppearingTwiceUsesTheEditedCopyOnlyWhenNoCopyIsIntact() {
        let both = "Hov said the new build is ready for review today. Hov said the new build is ready for review today"
        #expect(pairs(sentence, both) == ["Hove>Hov"])
        let oneIntact = "Hov said the new build is ready for review today. " + sentence
        #expect(pairs(sentence, oneIntact).isEmpty)
        #expect(pairs(sentence, sentence + " " + sentence).isEmpty)
    }

    @Test func unchangedTextProposesNothing() {
        #expect(pairs(sentence, sentence).isEmpty)
        #expect(pairs(sentence, "prefix " + sentence + " suffix").isEmpty)
    }

    @Test func capitalisationOnlyAndPunctuationOnlyChangesAreIgnored() {
        #expect(pairs("see you friday at noon in the lobby", "see you Friday at noon in the lobby").isEmpty)
        #expect(pairs("see you friday at noon in the lobby", "see you friday, at noon in the lobby!").isEmpty)
    }

    @Test func unrelatedWordSwapsAreIgnored() {
        #expect(pairs("Go to the bank before it closes today", "Go to the store before it closes today").isEmpty)
    }

    @Test func commonWordSwapsAreIgnoredUnlessTheCorrectionIsAName() {
        #expect(pairs("Put it over there with the rest of them", "Put it over their with the rest of them").isEmpty)
        #expect(pairs("There is a plan for the launch this week", "Their is a plan for the launch this week").isEmpty)
        #expect(pairs("Tell there that the lunch is ready now", "Tell Thayer that the lunch is ready now") == ["there>Thayer"])
    }

    @Test func aRewriteOfMoreThanHalfTheWordsIsEditingNotCorrecting() {
        #expect(pairs(sentence, "Hov said the fresh release is done for testing tonight").isEmpty)
        #expect(pairs("Hove said hello to praya and left", "Hov said hello to Priya and left") == ["Hove>Hov", "praya>Priya"])
    }

    @Test func pureDeletionsAndInsertionsAreIgnored() {
        #expect(pairs(sentence, "Hove said the build is ready for review today").isEmpty)
        #expect(pairs(sentence, "Hove said the new shiny build is ready for review today").isEmpty)
    }

    @Test func phrasesOfMoreThanThreeWordsAreIgnored() {
        let pasted = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike"
        #expect(pairs(pasted, "alpha bravocharliedeltaecho foxtrot golf hotel india juliet kilo lima mike").isEmpty)
        #expect(pairs(pasted, "alpha bravocharlie delta echo foxtrot golf hotel india juliet kilo lima mike") == ["bravo charlie>bravocharlie"])
    }

    @Test func aMissingOrUnrelatedFieldGivesUpCleanly() {
        #expect(pairs(sentence, "").isEmpty)
        #expect(pairs(sentence, "A completely different paragraph about gardening and soil").isEmpty)
        #expect(pairs("", sentence).isEmpty)
        #expect(pairs("Hove", "Hov").isEmpty)
    }

    @Test func numbersAndDigitsAloneAreNotVocabulary() {
        #expect(pairs("Meet at thirty in room tree this week please", "Meet at 30 in room 3 this week please").isEmpty)
    }

    @Test func theSamePairTwiceIsOfferedOnce() {
        let pasted = "Hove called and then hove emailed about the plan today"
        let field = "Hov called and then Hov emailed about the plan today"
        #expect(pairs(pasted, field) == ["Hove>Hov"])
    }

    @Test func changingALearnedRuleBackIsReportedAsARemoval() {
        let rule = DictionaryRule(heard: "hove", written: "Hov")
        let pasted = "Hov said the new build is ready for review today"
        let field = "Hove said the new build is ready for review today"
        let analysis = CorrectionLearner.analyse(pasted: pasted, field: field, learned: [rule])
        #expect(analysis.reverted == [rule] && analysis.proposals.isEmpty)
        let unlearned = CorrectionLearner.analyse(pasted: pasted, field: field)
        #expect(unlearned.reverted.isEmpty)
        let other = CorrectionLearner.analyse(pasted: pasted, field: "Haw said the new build is ready for review today", learned: [rule])
        #expect(other.reverted.isEmpty)
    }

    @Test func similarityMeasures() {
        #expect(CorrectionLearner.similar("hove", "Hov") && CorrectionLearner.similar("praya", "Priya"))
        #expect(CorrectionLearner.similar("mouth type", "Mouthtype") && CorrectionLearner.similar("zoe", "Zoë"))
        #expect(!CorrectionLearner.similar("bank", "store"))
        #expect(CorrectionLearner.soundex(Array("robert")) == "R163" && CorrectionLearner.soundex(Array("rupert")) == "R163")
        #expect(CorrectionLearner.soundex(Array("tymczak")) == "T522")
        #expect(TextMetrics.editDistance(Array("kitten"), Array("sitting")) == 3)
    }

    @Test func aHugeFieldIsRefusedRatherThanStalling() {
        let field = String(repeating: "word ", count: 100_000)
        #expect(pairs(sentence, field).isEmpty)
    }
}
