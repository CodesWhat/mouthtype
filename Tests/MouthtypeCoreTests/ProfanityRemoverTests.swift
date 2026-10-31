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
        ("It was fucking shit, honestly.", "It was stuff, honestly."),
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

    /// Swearing the sentence needs is swapped for a mild word.
    static let swapped: [(input: String, expected: String)] = [
        ("Don't be an asshole.", "Don't be a jerk."),
        ("He is a motherfucker.", "He is a jerk."),
        ("They are assholes.", "They are jerks."),
        ("Stop being a bitch about it.", "Stop being a jerk about it."),
        ("Such a bitch.", "Such a jerk."),
        ("Quit the bullshit and go.", "Quit the nonsense and go."),
        ("This is some crap.", "This is some junk."),
        ("Talk shit all day.", "Talk nonsense all day."),
        ("He talks shit about me.", "He talks nonsense about me."),
        ("It is a piece of shit.", "It is a piece of junk."),
        ("My shit is gone.", "My stuff is gone."),
        ("Pick up this shit.", "Pick up this stuff."),
        ("What a pain in the ass.", "What a pain in the neck."),
        ("I am pissed off.", "I am annoyed."),
        ("Pissed off about it.", "Annoyed about it."),
        ("That was a shitty day.", "That was a bad day."),
        ("I feel crappy today.", "I feel bad today."),
        ("It was a damned fool idea.", "It was a fool idea."),
        ("Damned fool.", "Fool."),
        ("Stop fucking around.", "Stop messing around."),
        ("Quit screwing around.", "Quit messing around."),
        ("Stop fucking up the build.", "Stop messing up the build."),
        ("I fucked up the build.", "I messed up the build."),
        ("Don't fuck up.", "Don't mess up."),
        ("Fuck this job.", "Forget this job."),
        ("I hate it, fuck that guy.", "I hate it, forget that guy."),
        ("Fuck, asshole.", "Jerk."),
        ("Holy shit, we shipped.", "We shipped."),
    ]

    @Test(arguments: swapped)
    func swapsNeededSwearingForAMildWord(_ pair: (input: String, expected: String)) {
        #expect(strip(pair.input) == pair.expected, "\(pair.input.debugDescription)")
    }

    /// Verb forms, split phrasal verbs and the article before whatever replaced the swear word.
    static let verbsAndArticles: [(input: String, expected: String)] = [
        ("I shit you not.", "I kid you not."),
        ("She bitches about work.", "She complains about work."),
        ("They bitched about it all day.", "They complained about it all day."),
        ("Stop bitching about it.", "Stop complaining about it."),
        ("I hate to bitch.", "I hate to complain."),
        ("He shits on everything.", "He dumps on everything."),
        ("Stop shitting on the plan.", "Stop dumping on the plan."),
        ("Those bitches are loud.", "Those jerks are loud."),
        ("I don't give a shit.", "I don't give a hoot."),
        ("I fucked it up.", "I messed it up."),
        ("He fucked the whole thing up.", "He messed the whole thing up."),
        ("They screwed it up.", "They screwed it up."),
        ("Don't fuck it up.", "Don't mess it up."),
        ("Stop fucking it up.", "Stop messing it up."),
        ("We're fucked.", "We're messed up."),
        ("Don't fuck with it.", "Don't mess with it."),
        ("Fuck me, that hurt.", "That hurt."),
        ("I fucked her.", "I slept with her."),
        ("He fucked Sarah.", "He messed up Sarah."),
        ("He fucked Excel.", "He messed up Excel."),
        ("They fucked us over.", "They cheated us."),
        ("They fucked over the team.", "They cheated the team."),
        ("You bitch about work.", "You complain about work."),
        ("You shit on everything.", "You dump on everything."),
        ("You bitch!", "You jerk!"),
        ("Stop bitchin' about it.", "Stop complaining about it."),
        ("She keeps bitchin'.", "She keeps complaining."),
        ("That's bitchin'.", "That's great."),
        ("That is a fucking unique idea.", "That is a unique idea."),
        ("He has a fucking MBA.", "He has an MBA."),
        ("It was a fucking UFO.", "It was a UFO."),
        ("It was a fucking FBI agent.", "It was an FBI agent."),
        ("He is a motherfucking NASA engineer.", "He is a NASA engineer."),
        ("It was a fucking NATO decision.", "It was a NATO decision."),
        ("It was a fucking OPEC meeting.", "It was an OPEC meeting."),
        ("It was a fucking JPEG file.", "It was a JPEG file."),
        ("He fucked her over the weekend.", "He slept with her over the weekend."),
        ("He fucked her over the summer.", "He slept with her over the summer."),
        ("He fucked me over lunch.", "He slept with me over lunch."),
        ("He fucked her over.", "He cheated her."),
        ("He fucked her over completely.", "He cheated her completely."),
        ("An asshole wrote 'an jerk'.", "A jerk wrote 'an jerk'."),
        ("That is a pissed off look.", "That is an annoyed look."),
        ("He is a pissed off guy.", "He is an annoyed guy."),
        ("She was a bit pissed off.", "She was a bit annoyed."),
        ("I was a fucking idiot.", "I was an idiot."),
        ("He is an asshole.", "He is a jerk."),
        ("He is a fucking annoying guy.", "He is an annoying guy."),
        ("That is a fucking university.", "That is a university."),
        ("It took a fucking hour.", "It took an hour."),
        ("It was a shitty idea.", "It was a bad idea."),
        ("A pissed off customer called.", "An annoyed customer called."),
        ("That damned asshole.", "That jerk."),
        ("Damned asshole.", "Jerk."),
        ("Kick his ass.", "Kick his butt."),
        ("That bitchin' car.", "That great car."),
        ("Bitchin' idea.", "Great idea."),
    ]

    @Test(arguments: verbsAndArticles)
    func handlesVerbsPhrasalVerbsAndArticles(_ pair: (input: String, expected: String)) {
        #expect(strip(pair.input) == pair.expected, "\(pair.input.debugDescription)")
    }

    static let copulaVerbs: [(input: String, expected: String)] = [
        ("He was fucking women.", "He was sleeping with women."),
        ("They were fucking women.", "They were sleeping with women."),
        ("We're fucking people.", "We're sleeping with people."),
        ("You were fucking people over.", "You were cheating people."),
        ("They were fucking people over the weekend.", "They were sleeping with people over the weekend."),
        ("They were fucking people over there.", "They were sleeping with people over there."),
        ("He fucked her over there.", "He slept with her over there."),
        ("He was fucking constantly.", "He was having sex constantly."),
        ("They were fucking frequently.", "They were having sex frequently."),
        ("He was fucking constantly late.", "He was constantly late."),
        ("They were fucking constantly running.", "They were constantly running."),
        ("The fucking people over there left.", "The people over there left."),
        ("I was fucking great up there.", "I was great up there."),
        ("She's fucking guys from work.", "She's sleeping with guys from work."),
        ("I was fucking people I barely knew.", "I was sleeping with people I barely knew."),
        ("It was fucking shit, honestly.", "It was stuff, honestly."),
        ("They were fucking morons.", "They were morons."),
        ("He was fucking idiot.", "He was idiot."),
        ("This is fucking great.", "This is great."),
        ("He was fucking furious.", "He was furious."),
        ("Stop fucking around.", "Stop messing around."),
        ("I have fucking kids.", "I have kids."),
        ("I have fucking diabetes.", "I have diabetes."),
        ("She is fucking guys trip planner.", "She is guys trip planner."),
        ("She was fucking hours late.", "She was hours late."),
        ("I am fucking days behind.", "I am days behind."),
        ("He was fucking miles away.", "He was miles away."),
        ("He was fucking things up.", "He was messing things up."),
        ("He was fucking people over.", "He was cheating people."),
        ("She was fucking guys around.", "She was messing guys around."),
        ("He was fucking people around here.", "He was sleeping with people around here."),
        ("They were fucking people around there.", "They were sleeping with people around there."),
        ("She was fucking guys around town.", "She was sleeping with guys around town."),
        ("He was fucking people around the office.", "He was sleeping with people around the office."),
        ("She was fucking guys around London.", "She was sleeping with guys around London."),
        ("They were fucking people around Christmas.", "They were sleeping with people around Christmas."),
        ("There were fucking people around here.", "There were people around here."),
        ("There are fucking people around.", "There are people around."),
        ("There were fucking guys around.", "There were guys around."),
        ("There have been fucking people around.", "There have been people around."),
        ("There will be fucking people around.", "There will be people around."),
        ("There might have been fucking people around.", "There might have been people around."),
        ("There. He has been fucking people around.", "There. He has been messing people around."),
        ("There he has been fucking people around.", "There he has been messing people around."),
        ("She was fucking guys around a lot.", "She was messing guys around a lot."),
        ("I'm fucking people-watching.", "I'm people-watching."),
        ("She was fucking guys-only trip planning.", "She was guys-only trip planning."),
    ]

    @Test(arguments: copulaVerbs)
    func keepsFuckingAsAVerbInClearCopulaUses(_ pair: (input: String, expected: String)) {
        #expect(strip(pair.input) == pair.expected, "\(pair.input.debugDescription)")
    }

    @Test func swapsFuckingForSleepingWithEvenWhenThePeopleNounIsProtected() {
        #expect(strip("He was fucking women.", protected: ["women"]) == "He was sleeping with women.")
    }

    @Test func leavesTheSpeakersOwnArticlesAlone() {
        for text in ["A apple a day.", "He is an hour late.", "A university, an hour, an honest man."] {
            #expect(strip(text) == text, "\(text.debugDescription)")
        }
        #expect(strip("A fucking apple a day.") == "An apple a day.")
    }

    @Test func articleRepairKeepsCapitalisation() {
        #expect(strip("A fucking idiot called.") == "An idiot called.")
        #expect(strip("An asshole called.") == "A jerk called.")
    }

    @Test func vowelSoundHeuristic() {
        for word in ["annoyed", "idiot", "hour", "honest", "honor", "umbrella", "unimportant", "unanswered", "egg"] {
            #expect(ProfanityRemover.startsWithVowelSound(word), "\(word)")
        }
        for word in ["jerk", "university", "unit", "one", "once", "euro", "user", "usual", "utility", "ubiquitous", "unanimous", "bad", "hat"] {
            #expect(!ProfanityRemover.startsWithVowelSound(word), "\(word)")
        }
    }

    /// Every inflection of every listed swear word has some outcome in Formal. "damn" and its forms stay for the model
    /// when they are not an exclamation or an intensifier, so only the ones that always go are swept here.
    @Test func noListedSwearSurvivesInAnyFrame() {
        let kept: Set<String> = ["damn", "damned", "goddamn", "goddamned"]
        let frames = [
            "%@", "Well, %@.", "He said %@ again.", "I %@ it.", "She %@ about work.", "That is a %@ idea.", "The %@ is here.",
            "Don't be %@.", "%@ the whole thing.", "They gave two %@.", "Stop %@ around.", "He %@ on everything.",
            "We %@ you not.", "What a %@!", "Such %@ people.", "It is %@ broken.",
        ]
        let swears = ProfanityRemover.words.subtracting(kept).sorted()
        var survivors: [String] = []
        for word in swears {
            for frame in frames {
                for form in [word, word.capitalized] {
                    let input = frame.replacingOccurrences(of: "%@", with: form)
                    let output = strip(input).lowercased()
                    let tokens = output.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                    if tokens.contains(where: { swears.contains($0) }) { survivors.append("\(input) -> \(output)") }
                }
            }
        }
        #expect(survivors.isEmpty, "\(survivors.joined(separator: "\n"))")
    }

    @Test func innocentWordsAreNotMistakenForSwearing() {
        for text in [
            "Shiitake soup and shitake rice.", "Scrap the plan.", "A crappie is a fish.", "Assess the damage.", "Mr. Cockburn called.",
            "Dickens wrote it.", "I live in Scunthorpe.", "Class is over.", "A passage from the book.", "Bass and glass.",
        ] {
            #expect(strip(text) == text, "\(text.debugDescription)")
        }
    }

    static let dismissals: [(input: String, expected: String)] = [
        ("Fuck you.", ""),
        ("Fuck off", ""),
        ("Fuck that.", ""),
        ("Fuck it.", ""),
        ("Fuck it, let's go.", "Let's go."),
        ("Fuck it we ship.", "We ship."),
        ("Screw you.", ""),
        ("Okay. Fuck you. Next.", "Okay. Next."),
        ("I told him to fuck off.", "I told him to."),
        ("Fuck you, man.", "Man."),
    ]

    @Test(arguments: dismissals)
    func dropsDismissivePhrases(_ pair: (input: String, expected: String)) {
        #expect(strip(pair.input) == pair.expected, "\(pair.input.debugDescription)")
    }

    @Test func keepsWordsThatAreNotSwearing() {
        for text in ["We are damned if we do.", "Damn it all.", "I screw in the bolt.", "Tighten the screw.", "He was pissed.", "Pick up the shell.", "A fine class."] {
            #expect(strip(text) == text, "\(text.debugDescription)")
        }
    }

    @Test func swapsRespectProtectedSpellingsAndPhrases() {
        #expect(strip("Don't be an asshole.", protected: ["asshole"]) == "Don't be an asshole.")
        #expect(ProfanityRemover(protectedPhrases: ["piece of shit"]).apply("It is a piece of shit.").text == "It is a piece of shit.")
        #expect(ProfanityRemover(protectedPhrases: ["fuck off"]).apply("Fuck off.").text == "Fuck off.")
        #expect(strip("Fuck this job.", protected: ["fuck"]) == "Fuck this job.")
    }

    @Test func swapsOnlyInFormal() {
        let text = "Don't be an asshole, stop fucking around, it is a piece of shit."
        #expect(pipeline(text, style: StylePreset.casual.options).hasPrefix("Don't be an asshole, stop fucking around, it is a piece of shit"))
        #expect(pipeline(text) == "Don't be a jerk, stop messing around, it is a piece of junk.")
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
        "Open shit.py now.", "See /tmp/crap/file", "It's hell out there.", "bull-shit",
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

    static let openingWithoutComma: [(input: String, expected: String)] = [
        ("Fuck this is a test and it's fucking great.", "This is a test and it's great."),
        ("Shit I forgot the keys.", "I forgot the keys."),
        ("Damn it's cold.", "It's cold."),
        ("Fuck we're late.", "We're late."),
        ("Okay. Crap we missed it.", "Okay. We missed it."),
        ("Fuck, this is a test.", "This is a test."),
    ]

    @Test(arguments: openingWithoutComma)
    func removesAnOpeningSwearBeforeANewClause(_ pair: (input: String, expected: String)) {
        #expect(strip(pair.input) == pair.expected, "\(pair.input.debugDescription)")
    }

    @Test func openingSwearWithoutCommaRespectsProtections() {
        #expect(strip("Fuck we're late.", protected: ["fuck"]) == "Fuck we're late.")
        #expect(ProfanityRemover(protectedPhrases: ["fuck this"]).apply("Fuck this is a test.").text == "Fuck this is a test.")
    }

    @Test func openingSwearWithoutCommaOnlyGoesInFormal() {
        let text = "Fuck this is a test and it's fucking great."
        #expect(pipeline(text, style: StylePreset.casual.options).contains("Fuck this is a test"))
        #expect(pipeline(text) == "This is a test and it's great.")
    }

    /// A leading space in a stored final text comes from insertion spacing after a word already in the field, not from
    /// the pipeline: removing the first word never leaves one.
    @Test func removingTheFirstWordLeavesNoLeadingSpace() {
        #expect(pipeline("Fuck this is a test and it's fucking great.").first == "T")
        #expect(pipeline("Fuck, this is a test.").first == "T")
        #expect(pipeline("Um this is a test.").first == "T")
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
        for c in Self.removals + Self.swapped + Self.dismissals {
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
            SmartCleanupRequest(
                text: "Deploy brain fuck today, it is late.", level: .medium, style: .formal,
                dictionary: [DictionaryRule(heard: "brain fuck", written: "Brainfuck")]))
        #expect(result.text.contains("Brainfuck") || result.text.contains("brain fuck"))
        #expect(!result.text.contains("fucking"))
    }
}
