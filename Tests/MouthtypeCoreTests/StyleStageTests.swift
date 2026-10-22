import Testing
@testable import MouthtypeCore

@Suite struct StyleStageTests {
    private func run(
        _ text: String, _ preset: StylePreset, context: InsertionContext? = nil,
        dictionary: [DictionaryRule] = [], snippets: [Snippet] = [], options: TextPipelineOptions? = nil
    ) -> TextPipelineResult {
        var o = options ?? TextPipelineOptions()
        if options == nil { o.style = preset.options }
        return TextPipeline(dateFormatter: { _ in "October 12, 2026" }).run(
            TextPipelineInput(
                text: text, dictionary: dictionary, snippets: snippets, context: context, options: o
            ))
    }

    private func style(_ text: String, _ options: StyleOptions, protected: Set<String> = []) -> StageResult {
        StyleStage(options: options, protectedWords: protected).apply(text)
    }

    // MARK: Presets and switches

    @Test func presetsAreCombinationsOfTheTwoSwitches() {
        #expect(StylePreset.formal.options == StyleOptions(capitalisation: .sentence, endingPunctuation: .keep))
        #expect(StylePreset.casual.options == StyleOptions(capitalisation: .sentence, endingPunctuation: .dropFinalFullStop))
        #expect(StylePreset.veryCasual.options == StyleOptions(capitalisation: .lowercase, endingPunctuation: .dropFinalFullStop))
        #expect(StyleOptions(capitalisation: .lowercase, endingPunctuation: .keep).preset == nil)
        #expect(StylePreset.casual.options.preset == .casual)
    }

    @Test func formalChangesNothing() {
        let out = run("Send it to Dana. Thanks.", .formal)
        #expect(out.text == "Send it to Dana. Thanks.")
        #expect(out.edits.isEmpty)
    }

    // MARK: Casual

    @Test func casualDropsTheFinalStopOfAShortMessage() {
        #expect(run("sounds good thanks", .casual).text == "Sounds good thanks")
        #expect(run("I will be there at five.", .casual).text == "I will be there at five")
        #expect(run("Sounds good. See you then.", .casual).text == "Sounds good. See you then")
    }

    @Test func casualKeepsQuestionAndExclamationMarks() {
        #expect(run("are you coming question mark", .casual).text == "Are you coming?")
        #expect(run("that is great exclamation point", .casual).text == "That is great!")
    }

    @Test func casualLeavesLongTextAlone() {
        let three = "One thing. Two things. Three things."
        #expect(style(three, StylePreset.casual.options).text == three)
        let words = (1...30).map { "word\($0)" }.joined(separator: " ") + "."
        #expect(style(words, StylePreset.casual.options).text == words)
    }

    @Test func casualKeepsEllipsisAndAbbreviations() {
        #expect(style("Well...", StylePreset.casual.options).text == "Well...")
        #expect(style("Well\u{2026}", StylePreset.casual.options).text == "Well\u{2026}")
        #expect(style("Bring cups, plates, etc.", StylePreset.casual.options).text == "Bring cups, plates, etc.")
        #expect(style("See you at 5 p.m.", StylePreset.casual.options).text == "See you at 5 p.m.")
    }

    @Test func casualKeepsCapitalsAndInternalPunctuation() {
        #expect(style("Hi Dana, I'm late. Sorry.", StylePreset.casual.options).text == "Hi Dana, I'm late. Sorry")
    }

    @Test func casualDropLogsAReplaceEditUnderBlend() {
        let out = style("See you Friday.", StylePreset.casual.options)
        #expect(out.text == "See you Friday")
        #expect(
            out.edits == [
                EditOp(
                    stage: "blend", kind: .replace, fromText: "Friday.", toText: "Friday", wordDelta: 0, position: 8
                )
            ])
    }

    // MARK: Very casual

    @Test func veryCasualLowercasesCommonSentenceStarts() {
        #expect(run("send the notes to Dana. then book the room.", .veryCasual).text == "send the notes to Dana. then book the room")
        #expect(run("Thanks. See you soon.", .veryCasual).text == "thanks. see you soon")
    }

    @Test func veryCasualLowercasesContractionsAtASentenceStart() {
        #expect(style("Let's go. Don't wait", StylePreset.veryCasual.options).text == "let's go. don't wait")
    }

    @Test func veryCasualKeepsI() {
        #expect(style("I think I'm right. I'll go.", StylePreset.veryCasual.options).text == "I think I'm right. I'll go")
        #expect(style("I'd say so", StylePreset.veryCasual.options).text == "I'd say so")
    }

    @Test func veryCasualKeepsAcronymsMixedCaseAndMidSentenceNames() {
        let o = StylePreset.veryCasual.options
        #expect(style("The NASA team met Dana at the iPhone store. McDonald agreed", o).text == "the NASA team met Dana at the iPhone store. McDonald agreed")
        #expect(style("OK sure", o).text == "OK sure")
        #expect(style("iPhone is out", o).text == "iPhone is out")
    }

    @Test func veryCasualKeepsASentenceInitialNameUnlessAlsoSeenLowercase() {
        let o = StylePreset.veryCasual.options
        #expect(style("Dana called. Congratulations", o).text == "Dana called. Congratulations")
        #expect(style("Congratulations to the team. congratulations again", o).text == "congratulations to the team. congratulations again")
        #expect(style("Dana will call. I asked dana", o).text == "dana will call. I asked dana")
    }

    @Test func veryCasualKeepsDictionaryAndSnippetWords() {
        let rules = [DictionaryRule(heard: "mouth type", written: "Mouthtype")]
        #expect(run("mouth type is fast", .veryCasual, dictionary: rules).text == "Mouthtype is fast")
        let snippets = [Snippet(trigger: "my sig", expansion: "Regards from Scott")]
        #expect(run("my sig", .veryCasual, snippets: snippets).text == "Regards from Scott")
    }

    @Test func veryCasualKeepsUrlsEmailsAndCode() {
        let o = StylePreset.veryCasual.options
        #expect(style("Email Dana@Example.com. Thanks", o).text == "email Dana@Example.com. thanks")
        #expect(style("Visit Example.com now", o).text == "visit Example.com now")
        #expect(style("Src/Main is ready", o).text == "Src/Main is ready")
        #expect(style("Snake_case is fine", o).text == "Snake_case is fine")
        #expect(style("See https://Example.com/Path. Then go", o).text == "see https://Example.com/Path. then go")
    }

    @Test func veryCasualLeavesQuotedTextAlone() {
        let o = StylePreset.veryCasual.options
        #expect(style("He said \"Hello there\". Then left", o).text == "he said \"Hello there\". then left")
    }

    @Test func veryCasualKeepsQuestionAndExclamationMarks() {
        #expect(run("are you coming question mark", .veryCasual).text == "are you coming?")
        #expect(run("that is great exclamation point", .veryCasual).text == "that is great!")
    }

    @Test func veryCasualLeavesListMarkersAndNumbersAlone() {
        let out = run("numbered list ship it next item call Sam about 20 retries", .veryCasual)
        #expect(out.text == "1. ship it\n2. call Sam about 20 retries")
    }

    // MARK: Lists and interaction

    @Test func listsKeepMarkersAndCapitalsInFormalAndCasual() {
        let text = "here is the list colon bullet ship it bullet call Sam"
        #expect(run(text, .formal).text == "Here is the list:\n- Ship it\n- Call Sam")
        #expect(run(text, .casual).text == "Here is the list:\n- Ship it\n- Call Sam")
        #expect(run(text, .veryCasual).text == "here is the list:\n- ship it\n- call Sam")
    }

    @Test func aDictationEndingInAListIsNotStripped() {
        #expect(run("groceries bullet milk bullet eggs.", .casual).text == "Groceries\n- Milk\n- Eggs.")
        #expect(run("here is the plan numbered list ship it next item call Sam.", .casual).text == "Here is the plan\n1. Ship it\n2. Call Sam.")
        #expect(run("here is the plan numbered list ship it next item call Sam.", .veryCasual).text == "here is the plan\n1. ship it\n2. call Sam.")
    }

    @Test func unlistedSentenceStartsKeepTheirCapitalInVeryCasual() {
        // The documented miss: "Milk" is not in the common-word list and appears nowhere in lowercase.
        #expect(run("bullet milk bullet eggs", .veryCasual).text == "- Milk\n- Eggs")
    }

    @Test func midSentenceContinuationStaysLowercaseInEveryStyle() {
        let ctx = InsertionContext(before: "I think we should", after: nil)
        for preset in StylePreset.allCases {
            let out = run("The deck is ready", preset, context: ctx)
            #expect(out.text.hasPrefix("the deck"), "\(preset)")
        }
    }

    @Test func styleLogsUnderBlendWithKindReplace() {
        let out = run("Thanks. See you soon.", .veryCasual)
        let style = out.edits.filter { $0.stage == "blend" }
        #expect(!style.isEmpty)
        #expect(style.allSatisfy { $0.kind == .replace })
        #expect(out.stageMillis["style"] != nil)
    }

    @Test func styleRunsAfterBlendAndBeforeWhitespace() {
        // Blend capitalises "thanks", then style lowercases it again; whitespace tidies last.
        let out = run("thanks   a lot", .veryCasual)
        #expect(out.text == "thanks a lot")
    }

    @Test func allStagesOffBypassesStyleToo() {
        var o = TextPipelineOptions.none
        let out = TextPipeline().run(TextPipelineInput(text: "Thanks. See you.", options: o))
        #expect(out.text == "Thanks. See you.")
        o.style = StylePreset.veryCasual.options
        let styled = TextPipeline().run(TextPipelineInput(text: "Thanks. See you.", options: o))
        #expect(styled.text == "thanks. see you")
    }

    @Test func styleSurvivesTheEditReplayCheck() {
        let out = run("Thanks. See you soon.", .veryCasual)
        #expect(!out.edits.isEmpty)
    }
}
