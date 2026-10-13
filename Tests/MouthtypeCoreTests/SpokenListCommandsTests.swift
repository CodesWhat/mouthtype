import Testing
@testable import MouthtypeCore

@Suite struct SpokenListCommandsTests {
    private func run(_ text: String) -> String {
        WhitespaceNormalizer().apply(SpokenCommands().apply(text).text)
    }

    private func full(_ text: String) -> String {
        TextPipeline().run(TextPipelineInput(text: text)).text
    }

    static let commands: [TextCase] = [
        TextCase("bullet milk bullet eggs", "- Milk\n- Eggs"),
        TextCase("bullet point milk bullet point eggs", "- Milk\n- Eggs"),
        TextCase("new bullet milk new bullet eggs", "- Milk\n- Eggs"),
        TextCase("shopping list colon bullet milk bullet eggs bullet coffee", "shopping list:\n- Milk\n- Eggs\n- Coffee"),
        TextCase("groceries bullet milk, bullet eggs", "groceries\n- Milk\n- Eggs"),
        TextCase("groceries bullet milk. bullet eggs.", "groceries\n- Milk.\n- Eggs."),
        TextCase("Groceries. Bullet milk. Bullet eggs.", "Groceries.\n- Milk.\n- Eggs."),
        TextCase("bullet milk next item eggs", "- Milk\n- Eggs"),
        TextCase("bullet milk new item eggs", "- Milk\n- Eggs"),
        TextCase("bullet milk next eggs", "- Milk\n- Eggs"),
        TextCase("numbered list restart the server next item clear the cache", "1. Restart the server\n2. Clear the cache"),
        TextCase("steps numbered list one next item two new item three", "steps\n1. One\n2. Two\n3. Three"),
        TextCase("numbered list apples next item pears numbered list kiwis next item plums", "1. Apples\n2. Pears\n1. Kiwis\n2. Plums"),
        TextCase("bullet milk end list thanks all", "- Milk\nThanks all"),
        TextCase("bullet milk end of list thanks all", "- Milk\nThanks all"),
        TextCase("bullet milk end list", "- Milk"),
        TextCase("bullet milk new paragraph thanks", "- Milk\n\nThanks"),
        TextCase("bullet milk new paragraph next week we ship", "- Milk\n\nNext week we ship"),
        TextCase("bullet milk bullet eggs end list then call Sam", "- Milk\n- Eggs\nThen call Sam"),
        TextCase("numbered list first milk bullet eggs", "1. First milk\n- Eggs"),
        TextCase("bullet milk new line bullet eggs", "- Milk\n- Eggs"),
    ]

    @Test(arguments: commands)
    func listCommands(_ c: TextCase) {
        #expect(run(c.input) == c.expected)
    }

    static let prose: [String] = [
        "the bullet hit the wall",
        "a bullet point on the slide",
        "what's next on the agenda",
        "the next item on the list is milk",
        "he fired a bullet",
        "that was the last bullet",
        "this is a numbered list of rules",
        "next item please",
        "we meet next week",
        "bullet points are useful",
        "take the bullet train",
        "check the end list",
        "the end of list processing",
        "I will bullet",
        "make it a bullet",
    ]

    @Test(arguments: prose)
    func proseSurvives(_ text: String) {
        let out = SpokenCommands().apply(text)
        #expect(out.text == text)
        #expect(out.edits.isEmpty)
    }

    @Test func nextInsideListNeedsAProseFreeContext() {
        #expect(run("bullet milk next week") == "- Milk next week")
        #expect(run("bullet ship what's next on the agenda") == "- Ship what's next on the agenda")
        #expect(run("bullet ship it by next friday") == "- Ship it by next friday")
        #expect(run("bullet milk next") == "- Milk next")
    }

    @Test func determinerBeforeNextItemKeepsItProseInsideAList() {
        #expect(run("bullet read the next item on the list") == "- Read the next item on the list")
    }

    @Test func newLineAndParagraphAreNotCommandsAfterADeterminer() {
        for text in ["a new line of products", "the new paragraph in the doc", "our new line", "my new line of work"] {
            let out = SpokenCommands().apply(text)
            #expect(out.text == text, "\(text)")
            #expect(out.edits.isEmpty)
        }
        #expect(run("Dana new line then book") == "Dana\nThen book")
        #expect(run("done new paragraph next steps") == "done\n\nNext steps")
    }

    @Test func logsListCommands() {
        let out = SpokenCommands().apply("groceries, bullet milk bullet eggs")
        let commands = out.edits.filter { $0.fromText?.contains("bullet") == true }
        #expect(commands.count == 2)
        #expect(commands.allSatisfy { $0.stage == "spoken command" && $0.kind == .replace })
        #expect(commands[0].fromText == ", bullet")
        #expect(commands[0].toText == "\n-")
    }

    @Test func noTrailingSpacesAndNoBlankLines() {
        let out = run("intro bullet one   bullet two  end list outro")
        #expect(out == "intro\n- One\n- Two\nOutro")
        #expect(!out.contains(" \n"))
        #expect(!out.contains("\n\n"))
    }

    // MARK: Through the whole pipeline

    @Test func fillersAndNumbersAroundLists() {
        #expect(
            full("numbered list um first restart the server next item twenty retries")
                == "1. First restart the server\n2. 20 retries"
        )
    }

    @Test func listAfterTextAndBeforeText() {
        #expect(
            full("here is the plan bullet build bullet test end list that is all")
                == "Here is the plan\n- Build\n- Test\nThat is all"
        )
    }

    @Test func listCommandsFollowTheSpokenCommandsSwitch() {
        let off = TextPipelineOptions(spokenCommands: false)
        let out = TextPipeline().run(TextPipelineInput(text: "bullet milk bullet eggs", options: off))
        #expect(!out.text.contains("- "))
    }

    @Test func listAtTextStartKeepsItsMarkerWithContext() {
        let ctx = InsertionContext(before: "I think", after: nil)
        let out = TextPipeline().run(TextPipelineInput(text: "bullet milk bullet eggs", context: ctx))
        #expect(out.text == "- Milk\n- Eggs")
    }
}
