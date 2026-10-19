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
        ("Damn it, I lost it.", "I lost it."),
        ("I lost it, dammit.", "I lost it."),
        ("Goddamn, that is good.", "That is good."),
        ("It was fucking shit, honestly.", "It was shit, honestly."),
        ("I drove a goddamn car.", "I drove a car."),
        ("That is damn good.", "That is good."),
        ("Fuck!!", ""),
        ("Fuck;", ""),
        ("Shit... I forgot.", "I forgot."),
        ("Okay. Shit!! Next one.", "Okay. Next one."),
        ("Fuck?! I forgot.", "I forgot."),
        ("This goddamn car is slow.", "This car is slow."),
        ("Damn good coffee.", "Good coffee."),
        ("It broke and, fuck, it stayed broken.", "It broke and it stayed broken."),
    ]

    /// Nouns and objects stay; the model levels smooth those over.
    static let nounsKept = [
        "Don't be an asshole.", "He is a motherfucker.", "Quit the bullshit and go.", "Stop being a bitch about it.",
        "This is some crap.", "Talk shit all day.", "It is a piece of shit.", "My shit is gone.", "Damn it all.",
        "Such a bitch.", "Fuck off.", "Stop fucking around.", "I feel crappy today.", "We are damned if we do.",
        "That was a shitty day.", "Stop fucking up the build.",
    ]

    @Test func keepsNounsAndObjects() {
        for text in Self.nounsKept {
            #expect(strip(text) == text, "\(text.debugDescription)")
        }
    }

    @Test func capitalisationRepairSkipsSavedSpellingsAndIdentifiers() {
        #expect(strip("Fuck, npm is broken.", protected: ["npm"]) == "npm is broken.")
        #expect(strip("Fuck, foo.py is missing.") == "foo.py is missing.")
        #expect(strip("Shit, build_2 failed.") == "build_2 failed.")
        #expect(strip("Shit, a/b failed.") == "a/b failed.")
        #expect(strip("Fuck, iPhone is broken.") == "iPhone is broken.")
        #expect(strip("Fuck, the build is broken.") == "The build is broken.")
    }

    @Test func protectedPhrasesAreNeverCut() {
        let remover = ProfanityRemover(protectedPhrases: ["holy shit", "brain fuck", "damn good coffee"])
        #expect(remover.apply("Holy shit, this is fucking broken.").text == "Holy shit, this is broken.")
        #expect(remover.apply("Deploy brain fuck.").text == "Deploy brain fuck.")
        #expect(remover.apply("I want damn good coffee.").text == "I want damn good coffee.")
        #expect(remover.apply("Fuck, I want damn good coffee.").text == "I want damn good coffee.")
    }

    @Test func intensifiersGoOnlyWhenTheNextWordIsModified() {
        #expect(strip("It is fucking great") == "It is great")
        #expect(strip("fucking great") == "Great")
        #expect(strip("this goddamn car") == "this car")
        #expect(strip("I want damn good coffee") == "I want good coffee")
        #expect(strip("damn good coffee") == "Good coffee")
    }

    @Test func overlappingProtectedPhrasesAllKeepTheirCover() {
        let remover = ProfanityRemover(protectedPhrases: ["oh my", "my damn project"])
        #expect(remover.apply("Oh my damn project is late.").text == "Oh my damn project is late.")
    }

    @Test func aProtectedWordKeepsTheDamnItPhrase() {
        #expect(strip("Damn IT.", protected: ["IT"]) == "Damn IT.")
        #expect(strip("Damn it.") == "")
    }

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
        let basic = TextPipeline().run(TextPipelineInput(text: "Fuck, tell Alice that this is fucking late, damn it."))
        #expect(basic.text == "Tell Alice that this is late.")
        let cleaner = FakeCleaner { text, _ in text }
        cleaner.usesNativeControls = false
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: basic.text, level: .medium, style: .formal))
        #expect(result.outcome == .ok)
        #expect(result.text == basic.text)
    }

    @Test func theModelsReplacementForANounIsNotUndone() async {
        let cleaner = FakeCleaner(returning: "Please do not be a jerk to Alice about the late delivery today.")
        cleaner.usesNativeControls = false
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "Please do not be an asshole to Alice about the late delivery today.", level: .medium, style: .formal))
        #expect(result.text == "Please do not be a jerk to Alice about the late delivery today.", "\(result.outcome) \(result.rejection ?? "")")
    }

    @Test func protectedPhrasesSurviveAfterTheModel() async {
        let cleaner = FakeCleaner(returning: "Deploy brain fuck today, it is fucking late.")
        cleaner.usesNativeControls = false
        let result = await SmartCleanup(cleaner: cleaner).run(
            SmartCleanupRequest(text: "Deploy brain fuck today, it is late.", level: .medium, style: .formal,
                                dictionary: [DictionaryRule(heard: "brain fuck", written: "Brainfuck")]))
        #expect(result.text.contains("Brainfuck") || result.text.contains("brain fuck"))
        #expect(!result.text.contains("fucking"))
    }
}
