import Testing
@testable import MouthtypeCore

@Suite struct ProfanityRemoverTests {
    private func strip(_ text: String, protected: Set<String> = []) -> String {
        ProfanityRemover(protectedWords: protected).apply(text).text
    }

    private func pipeline(_ text: String, style: StyleOptions = .formal, dictionary: [DictionaryRule] = []) -> String {
        var options = TextPipelineOptions()
        options.style = style
        return TextPipeline().run(TextPipelineInput(text: text, dictionary: dictionary, options: options)).text
    }

    static let removals: [(input: String, expected: String)] = [
        ("This is fucking great.", "This is great."),
        ("Fucking great.", "Great."),
        ("what the fuck is this", "what is this"),
        ("What the hell is this?", "What is this?"),
        ("Shit, I forgot.", "I forgot."),
        ("I forgot, shit.", "I forgot."),
        ("Well, fuck, I forgot.", "Well, I forgot."),
        ("Fuck.", ""),
        ("Okay. Fuck. Next one.", "Okay. Next one."),
        ("Okay. Fuck.", "Okay."),
        ("That was a shitty day.", "That was a day."),
        ("He is a motherfucker.", "He is a."),
        ("Quit the bullshit and go.", "Quit the and go."),
        ("Damn it, I lost it.", "I lost it."),
        ("Goddamn, that is good.", "That is good."),
        ("Don't be an asshole.", "Don't be an."),
        ("Stop being a bitch about it.", "Stop being a about it."),
        ("This is some crap.", "This is some."),
        ("It was fucking shit, honestly.", "It was honestly."),
    ]

    @Test func removesAndRepairs() {
        for c in Self.removals {
            #expect(strip(c.input) == c.expected, "\(c.input.debugDescription)")
        }
    }

    @Test func caseInsensitive() {
        #expect(strip("WHAT THE FUCK") == "WHAT")
        #expect(strip("This is FUCKING great") == "This is great")
    }

    static let untouched = [
        "Please assess the class.", "Scunthorpe won.", "Say hello to the shell.", "Dickens wrote it.", "He is a badass.",
        "Open shit.py now.", "See /tmp/crap/file", "It's hell out there.", "I'm pissed off.", "bull-shit",
        "Cockburn and Hancock met.", "The grass is green.", "A passenger and a compass.",
    ]

    @Test func leavesOrdinaryWordsAlone() {
        for text in Self.untouched {
            #expect(strip(text) == text, "\(text.debugDescription)")
        }
    }

    @Test func savedSpellingsAreKept() {
        #expect(strip("Ask Damn about it.", protected: ["Damn"]) == "Ask Damn about it.")
        #expect(strip("The crap project is fucking late.", protected: ["crap"]) == "The crap project is late.")
    }

    @Test func realTake() {
        let raw = "Um, this is a test ... um Fuck, what was I gonna say? Uh yeah, just tell Alice to message me."
        let out = pipeline(raw)
        #expect(!out.lowercased().contains("fuck"))
        #expect(out.contains("What was I gonna say?"))
        #expect(out.hasSuffix("Yeah, just tell Alice to message me."))
    }

    @Test func nonFormalTonesKeepSwearing() {
        let text = "This is fucking great."
        #expect(pipeline(text, style: StylePreset.casual.options).contains("fucking"))
        #expect(pipeline(text, style: StylePreset.veryCasual.options).contains("fucking"))
        #expect(pipeline(text).contains("fucking") == false)
    }

    @Test func pipelineSkipsDictionaryWords() {
        let rule = DictionaryRule(heard: "crappy bird", written: "Crappy Bird")
        #expect(pipeline("I love Crappy Bird, it is fucking hard.", dictionary: [rule]) == "I love Crappy Bird, it is hard.")
    }

    @Test func optionTurnsItOff() {
        var options = TextPipelineOptions()
        options.profanity = false
        let out = TextPipeline().run(TextPipelineInput(text: "This is fucking great.", options: options))
        #expect(out.text == "This is fucking great.")
    }

    @Test func replayMatchesOutput() {
        for c in Self.removals {
            let out = ProfanityRemover().apply(c.input)
            #expect(
                TextTestSupport.replay(out.edits, on: c.input) == TextTestSupport.stripWhitespace(out.text),
                "replay failed for \(c.input.debugDescription)"
            )
        }
    }

    @Test func idempotent() {
        for c in Self.removals {
            let once = strip(c.input)
            #expect(strip(once) == once, "\(c.input.debugDescription)")
        }
    }
}

@Suite struct ProfanityModelLevelTests {
    @Test(arguments: [false, true])
    func theModelCannotBringSwearingBack(native: Bool) async {
        let cleaner = FakeCleaner(returning: "This is fucking great, and I love it.")
        cleaner.usesNativeControls = native
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "This is great and I love it.", level: .medium, style: .formal))
        #expect(result.outcome == .ok)
        #expect(result.text == "This is great, and I love it.")
    }

    @Test func casualModelOutputKeepsSwearing() async {
        let cleaner = FakeCleaner(returning: "This is fucking great, and I love it.")
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "This is fucking great and I love it", level: .medium, style: StylePreset.casual.options))
        #expect(result.text.contains("fucking"))
    }

    @Test func sharedPromptAsksFormalToOmitSwearing() async {
        let cleaner = FakeCleaner { text, _ in text }
        cleaner.usesNativeControls = false
        _ = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "This is great and I love it.", level: .medium, style: .formal))
        #expect(cleaner.contexts.contains { $0.omitProfanity })
        let formal = CleanupPrompt.system(for: CleanupContext(omitProfanity: true))
        let plain = CleanupPrompt.system(for: CleanupContext())
        #expect(formal.contains("leave out swearing") && !plain.contains("leave out swearing"))
        #expect(formal != plain)
    }

    @Test func theGuardSeesCleanedInput() async {
        // Basic already removed the swearing, so the model returning it unchanged does not trip the word-drop guard.
        let basic = TextPipeline().run(TextPipelineInput(text: "fuck shit damn crap fucking hell"))
        #expect(basic.text.lowercased().contains("fuck") == false)
        let cleaner = FakeCleaner { text, _ in text }
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "Tell Alice to message me today.", level: .medium, style: .formal))
        #expect(result.outcome == .ok)
    }
}
