import Testing
@testable import MouthtypeCore

@Suite struct FillerRemoverTests {
    static let removals: [TextCase] = [
        TextCase("um so I think we should uh ship it", "So I think we should ship it"),
        TextCase("Um, so we go", "So we go"),
        TextCase("we should uh, ship it", "we should ship it"),
        TextCase("we should, uh ship it", "we should ship it"),
        TextCase("I think, um, we should go", "I think, we should go"),
        TextCase("I went there, um.", "I went there."),
        TextCase("I went there um.", "I went there."),
        TextCase("ship it uh", "ship it"),
        TextCase("ship it, uh", "ship it"),
        TextCase("Er, the plan", "The plan"),
        TextCase("well erm that works", "well that works"),
        TextCase("Hmm, let me think", "Let me think"),
        TextCase("it was mm good", "it was good"),
        TextCase("Okay. Um. Then we ship.", "Okay. Then we ship."),
        TextCase("Um, uh, so we go", "So we go"),
        TextCase("uhm", ""),
        TextCase("line one\num next line", "line one\nNext line"),
        TextCase("um the iPhone", "The iPhone"),
        TextCase("um iPhone is out", "iPhone is out"),
        TextCase("hello uh\nworld", "hello\nworld"),
    ]

    @Test(arguments: removals)
    func fillers(_ c: TextCase) {
        let out = FillerRemover().apply(c.input)
        #expect(WhitespaceNormalizer().apply(out.text) == c.expected)
    }

    static let stutters: [TextCase] = [
        TextCase("bring the the deck", "bring the deck"),
        TextCase("I I I think so", "I think so"),
        TextCase("The the deck", "The deck"),
        TextCase("we we should go", "we should go"),
        TextCase("it's it's fine", "it's fine"),
        TextCase("the um the deck", "the deck"),
    ]

    @Test(arguments: stutters)
    func stutterRepeats(_ c: TextCase) {
        let out = FillerRemover().apply(c.input)
        #expect(WhitespaceNormalizer().apply(out.text) == c.expected)
    }

    static let untouched: [String] = [
        "I had had enough",
        "I know that that is true",
        "what it is is unclear",
        "bye bye now",
        "no no, that's wrong",
        "it is very very good",
        "it was so so",
        "call 555 555 now",
        "he had two two-pound bags",
        "one one one",
        "I like it, you know, actually it's sort of fine and kind of cool, I mean really",
        "the ER was busy",
        "uh-huh okay",
        "mm-hmm yes",
        "Hmm? what",
        "word-er thing",
        "e.g. the player",
        "user@um.com",
        "ha ha ha that's funny",
        "Hello world.",
        "",
        "12345",
        "UH huh okay",
    ]

    @Test(arguments: untouched)
    func leavesAlone(_ text: String) {
        let out = FillerRemover().apply(text)
        #expect(out.text == text, "changed \(text.debugDescription) to \(out.text.debugDescription)")
        #expect(out.edits.isEmpty)
    }

    @Test func unicodeRepeatsAreStutters() {
        #expect(FillerRemover().apply("café café is a bar").text == "café is a bar")
        #expect(FillerRemover().apply("你好 你好").text == "你好")
    }

    @Test func emojiAndSymbolsSurvive() {
        let text = "um 🎉 party 🎉 uh time 😀"
        let out = FillerRemover().apply(text)
        #expect(out.text == "🎉 party 🎉 time 😀")
    }

    @Test func removalLogsEveryChange() {
        let out = FillerRemover().apply("um so I think we should uh ship it")
        #expect(out.text == "So I think we should ship it")
        #expect(out.edits.count == 3)
        let um = out.edits[0]
        #expect(um.stage == "filler")
        #expect(um.kind == .delete)
        #expect(um.fromText == "um")
        #expect(um.toText == nil)
        #expect(um.wordDelta == -1)
        #expect(um.position == 0)
        let cap = out.edits[1]
        #expect(cap.kind == .replace)
        #expect(cap.fromText == "so")
        #expect(cap.toText == "So")
        #expect(cap.wordDelta == 0)
        #expect(cap.position == 3)
        let uh = out.edits[2]
        #expect(uh.fromText == "uh")
        #expect(uh.position == 24)
    }

    @Test func stutterEdit() {
        let out = FillerRemover().apply("bring the the deck")
        #expect(out.edits.count == 1)
        #expect(out.edits[0].fromText == "the")
        #expect(out.edits[0].position == 10)
        #expect(out.edits[0].wordDelta == -1)
    }

    @Test func replayMatchesOutput() {
        for c in Self.removals + Self.stutters {
            let out = FillerRemover().apply(c.input)
            #expect(
                TextTestSupport.replay(out.edits, on: c.input) == TextTestSupport.stripWhitespace(out.text),
                "replay failed for \(c.input.debugDescription)"
            )
        }
    }
}
