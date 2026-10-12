import Testing
@testable import MouthtypeCore

@Suite struct SpokenCommandsTests {
    private func run(_ text: String) -> String {
        WhitespaceNormalizer().apply(SpokenCommands().apply(text).text)
    }

    static let commands: [TextCase] = [
        // Layout is always a command.
        TextCase("bring the deck new line thanks", "bring the deck\nThanks"),
        TextCase("bring the deck newline thanks", "bring the deck\nThanks"),
        TextCase("first part new paragraph second part", "first part\n\nSecond part"),
        TextCase("PM. New line. Bring the deck", "PM.\nBring the deck"),
        TextCase("Hello new line", "Hello\n"),
        // Clause-end words.
        TextCase("I'm done period", "I'm done."),
        TextCase("I'm done period Next one", "I'm done. Next one"),
        TextCase("are you sure question mark", "are you sure?"),
        TextCase("are you sure question mark yes", "are you sure? Yes"),
        TextCase("wow exclamation point", "wow!"),
        TextCase("wow exclamation mark that's great", "wow! That's great"),
        TextCase("the list comma Then more", "the list, Then more"),
        TextCase("dear Sam comma", "dear Sam,"),
        TextCase("dear Sam comma I hope", "dear Sam, I hope"),
        TextCase("note colon Buy milk", "note: Buy milk"),
        TextCase("this one semicolon that one", "this one; that one"),
        TextCase("he stopped full stop", "he stopped."),
        TextCase("wait ellipsis what", "wait… what"),
        TextCase("wait dot dot dot what", "wait… what"),
        // Parakeet already punctuated next to the spoken word.
        TextCase("hello comma, world", "hello, world"),
        TextCase("Hello, comma, world", "Hello, world"),
        TextCase("It is done period.", "It is done."),
        TextCase("Is it done question mark?", "Is it done?"),
        TextCase("It is done. Period.", "It is done."),
        TextCase("hello comma. World", "hello, World"),
        // Symbols.
        TextCase("see the notes open paren page two close paren for more", "see the notes (page two) for more"),
        TextCase("he said open quote hello there close quote and left", "he said \"hello there\" and left"),
        TextCase("she said open quote hi end quote", "she said \"hi\""),
        TextCase("a well hyphen known fact", "a well-known fact"),
        TextCase("wait dash what", "wait - what"),
        TextCase("john at sign example", "john@example"),
        TextCase("Tom ampersand Jerry", "Tom & Jerry"),
        // Capitals.
        TextCase("it ends question mark and then", "it ends? And then"),
        TextCase("one period Two period Three", "one. Two. Three"),
    ]

    @Test(arguments: commands)
    func converts(_ c: TextCase) {
        #expect(run(c.input) == c.expected)
    }

    static let ordinary: [String] = [
        "the trial period ended",
        "I'm done period next one",
        "one period two period three",
        "during the grace period we waited",
        "a period of time",
        "the period",
        "I put a comma in the wrong place",
        "this comma splice is wrong",
        "I'm in a coma... comma splice",
        "the colon cancer screening",
        "my colon hurts",
        "an exclamation point is loud",
        "she added a question mark to the title",
        "the semicolon key is stuck",
        "a quick dash to the store",
        "the hyphen key",
        "he came to a full stop at the light",
        "the first period was short",
        "periodic table",
        "commas and periods",
        "That is the end",
        "",
        "你好,世界。",
        "😀 period of joy",
    ]

    @Test(arguments: ordinary)
    func leavesOrdinaryUseAlone(_ text: String) {
        let out = SpokenCommands().apply(text)
        #expect(out.text == text)
        #expect(out.edits.isEmpty)
    }

    @Test func editLogForCommands() {
        let out = SpokenCommands().apply("hello comma, world new line bye")
        #expect(out.text == "hello, world\nBye")
        #expect(out.edits.count == 3)
        let comma = out.edits[0]
        #expect(comma.stage == "spoken command")
        #expect(comma.kind == .replace)
        #expect(comma.fromText == "comma,")
        #expect(comma.toText == ",")
        #expect(comma.wordDelta == 0)
        #expect(comma.position == 6)
        let newline = out.edits[1]
        #expect(newline.fromText == "new line")
        #expect(newline.toText == "\n")
        #expect(newline.wordDelta == -2)
        let cap = out.edits[2]
        #expect(cap.fromText == "bye")
        #expect(cap.toText == "Bye")
    }

    @Test func replayMatchesOutput() {
        for c in Self.commands {
            let out = SpokenCommands().apply(c.input)
            #expect(
                TextTestSupport.replay(out.edits, on: c.input) == TextTestSupport.stripWhitespace(out.text),
                "replay failed for \(c.input.debugDescription)"
            )
        }
    }

    @Test func tableIsTheOnlyVocabulary() {
        let custom = SpokenCommands(entries: [SpokenCommand(["bang"], "!", .unlessNoun, .previous, endsSentence: true)])
        #expect(WhitespaceNormalizer().apply(custom.apply("wow bang").text) == "wow!")
        #expect(custom.apply("new line").text == "new line")
    }

    @Test func cjkAndEmojiAreNotMangled() {
        #expect(run("你好 new line 世界") == "你好\n世界")
        #expect(run("party 😀 comma Then more") == "party 😀, Then more")
    }
}
