import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct CountedListsTests {
    /// The stage alone, then the whitespace tidy the pipeline always ends with.
    private func stage(_ text: String) -> String {
        WhitespaceNormalizer().apply(CountedLists().apply(text).text)
    }

    private func full(_ text: String, style: StyleOptions = .formal) -> String {
        TextPipeline().run(TextPipelineInput(text: text, options: TextPipelineOptions(style: style))).text
    }

    static let positives: [TextCase] = [
        TextCase(
            "Three things. One, call the bank. Two, email Priya. Three, book the flight.",
            "Three things:\n1. Call the bank.\n2. Email Priya.\n3. Book the flight."
        ),
        TextCase(
            "I need to do three things today. First, call the bank. Second, email Priya. Third, book the flight.",
            "I need to do three things today:\n1. Call the bank.\n2. Email Priya.\n3. Book the flight."
        ),
        // Unpunctuated ordinals qualify, bare cardinals do not (see the negatives).
        TextCase(
            "first restart the server second clear the cache third run the tests",
            "1. Restart the server\n2. Clear the cache\n3. Run the tests"
        ),
        TextCase("Number one, the price. Number two, the timing.", "1. The price.\n2. The timing."),
        TextCase(
            "Step one, unplug it. Step two, wait ten seconds. Step three, plug it back in.",
            "1. Unplug it.\n2. Wait ten seconds.\n3. Plug it back in."
        ),
        TextCase("Step 1, unplug it. Step 2, plug it in.", "1. Unplug it.\n2. Plug it in."),
        TextCase(
            "Firstly, check the logs. Secondly, restart. Lastly, tell the team.",
            "1. Check the logs.\n2. Restart.\n3. Tell the team."
        ),
        TextCase(
            "First, check the logs. Second, restart. Third, wait. Finally, tell the team.",
            "1. Check the logs.\n2. Restart.\n3. Wait.\n4. Tell the team."
        ),
        TextCase("Point one, it's late. Point two, it's over budget.", "1. It's late.\n2. It's over budget."),
        TextCase(
            "Option a, the cheap one. Option b, the fast one.", "1. The cheap one.\n2. The fast one."
        ),
        TextCase("(a) the cheap one (b) the fast one", "1. The cheap one\n2. The fast one"),
        TextCase(
            "First of all, check the logs. Second, restart. Third, wait.",
            "1. Check the logs.\n2. Restart.\n3. Wait."
        ),
        // Digits as an engine may write them.
        TextCase("1, call the bank. 2, email Priya.", "1. Call the bank.\n2. Email Priya."),
        // A list followed by prose: the prose goes to its own line.
        TextCase(
            "Two things. First, call the bank. Second, email Priya. Then I'm done for the day.",
            "Two things:\n1. Call the bank.\n2. Email Priya.\nThen I'm done for the day."
        ),
        // Two separate lists.
        TextCase(
            "Morning. First, coffee. Second, email. Afternoon. First, lunch. Second, a walk.",
            "Morning.\n1. Coffee.\n2. Email.\nAfternoon.\n1. Lunch.\n2. A walk."
        ),
        TextCase(
            "One, coffee. Two, email. One, lunch. Two, a walk.",
            "1. Coffee.\n2. Email.\n1. Lunch.\n2. A walk."
        ),
        // Lead-in punctuation is only changed when it announces a count.
        TextCase("Here is the plan. First, a. Second, b.", "Here is the plan.\n1. A.\n2. B."),
        TextCase("Here are the following. First, a. Second, b.", "Here are the following:\n1. A.\n2. B."),
        TextCase("Do you know what to do? First, a. Second, b.", "Do you know what to do?\n1. A.\n2. B."),
        TextCase("A few things. First, a. Second, b.", "A few things:\n1. A.\n2. B."),
        // Lead-in counts that disagree with the items still make a list.
        TextCase("Three things. First, a. Second, b.", "Three things:\n1. A.\n2. B."),
        // The shape the speech engine really returns: one sentence, comma-introduced lowercase markers.
        TextCase(
            "Three things, one call the bank, two email priya, three book the flight.",
            "Three things:\n1. Call the bank\n2. Email priya\n3. Book the flight."
        ),
        TextCase(
            "I need to do three things today, first call the bank, second email priya, third book the flight.",
            "I need to do three things today:\n1. Call the bank\n2. Email priya\n3. Book the flight."
        ),
        TextCase("Two options, one call the bank, two email priya.", "Two options:\n1. Call the bank\n2. Email priya."),
        TextCase("Well, first call the bank, second email priya.", "Well\n1. Call the bank\n2. Email priya."),
        TextCase("Okay, one call the bank, two email priya, three book it.", "Okay\n1. Call the bank\n2. Email priya\n3. Book it."),
        // Items on lines of their own already.
        TextCase("First, a.\nSecond, b.", "1. A.\n2. B."),
        // Commas between items, a trailing comma is dropped.
        TextCase("First, call the bank, second, email Priya, third, book it.", "1. Call the bank\n2. Email Priya\n3. Book it."),
        // Capital and punctuation of the item stay.
        TextCase("First, iPhone repairs. Second, what's next?", "1. iPhone repairs.\n2. What's next?"),
        // Keeps other text before the list.
        TextCase("Hey Sam. First, a. Second, b.", "Hey Sam.\n1. A.\n2. B."),
    ]

    @Test(arguments: positives)
    func positive(_ c: TextCase) {
        #expect(stage(c.input) == c.expected)
    }

    static let negatives: [String] = [
        "One of them is broken and two are fine.",
        "The first time I tried it, it failed. The second time it worked.",
        "First, thanks for coming.",
        "We came second in the first round and third overall.",
        "I have one, two, three apples",
        "One, two, three apples",
        "Two thirty works. Three is too late.",
        "On the one hand it's cheap. On the other, it's slow.",
        "Version one was slow. Version two is fast.",
        "Number one priority is shipping.",
        "Number one is the price. Number two is the timing.",
        "One day we'll know. Two days later it broke.",
        "I came first. Then I came second.",
        "Last night I slept well.",
        "First time I tried it, it failed. Second time it worked.",
        "Second, call the bank. Third, email Priya.",
        "First, call the bank. Third, email Priya.",
        "One, call the bank. Three, email Priya.",
        "Option a is cheap. Option b is fast.",
        "I want a cheaper one. And a faster one.",
        "Press one, then press two for sales.",
        "First, thanks. Finally, goodbye.",
        "- first milk\n- second eggs",
        "1. First milk\n2. Second eggs",
        "we need one more, two at most",
        "Two thirty works, three is too late.",
        "Well, one more, two at most.",
        "Well, one call the bank, two email priya.",
        "I have one, two, three apples, four pears",
        "Chapter one, the start. Chapter two, the end.",
        "",
        "first",
        "one,",
    ]

    @Test(arguments: negatives)
    func negative(_ text: String) {
        #expect(stage(text) == text)
        #expect(CountedLists().apply(text).edits.isEmpty)
    }

    @Test func existingListLinesAreLeftAlone() {
        let text = "Plan:\n1. First milk\n2. Second eggs\nDone."
        #expect(stage(text) == text)
    }

    @Test func commandListsAreNotRecountedInPipeline() {
        #expect(full("numbered list first milk next item second eggs") == "1. First milk\n2. Second eggs")
    }

    // MARK: Log

    @Test func logsOneReplaceEditPerMarker() {
        let text = "Three things. One, call the bank. Two, email Priya. Three, book the flight."
        let result = CountedLists().apply(text)
        #expect(result.edits.count == 3)
        for e in result.edits {
            #expect(e.stage == "spoken command")
            #expect(e.kind == .replace)
        }
        #expect(TextTestSupport.replay(result.edits, on: text) == TextTestSupport.stripWhitespace(result.text))
    }

    @Test func logIncludesTheBreakBeforeFollowingProseOnlyAsLayout() {
        let text = "First, a. Second, b. Thanks all."
        let result = CountedLists().apply(text)
        #expect(result.edits.count == 2)
        #expect(result.text == "1. A.\n2. B.\nThanks all.")
        #expect(TextTestSupport.replay(result.edits, on: text) == TextTestSupport.stripWhitespace(result.text))
    }

    @Test func replaysForEveryPositive() {
        for c in Self.positives {
            let result = CountedLists().apply(c.input)
            #expect(
                TextTestSupport.replay(result.edits, on: c.input) == TextTestSupport.stripWhitespace(result.text),
                "\(c.input.debugDescription)"
            )
        }
    }

    @Test func idempotentOnTheStage() {
        for c in Self.positives {
            let once = CountedLists().apply(c.input).text
            #expect(CountedLists().apply(once).text == once, "\(c.input.debugDescription)")
        }
    }

    // MARK: Pipeline

    static let pipelineCases: [TextCase] = [
        TextCase(
            "Three things. One, call the bank. Two, email Priya. Three, book the flight.",
            "Three things:\n1. Call the bank.\n2. Email Priya.\n3. Book the flight."
        ),
        TextCase(
            "I need to do three things today. First, call the bank. Second, email Priya. Third, book the flight.",
            "I need to do three things today:\n1. Call the bank.\n2. Email Priya.\n3. Book the flight."
        ),
        TextCase(
            "first restart the server second clear the cache third run the tests",
            "1. Restart the server\n2. Clear the cache\n3. Run the tests"
        ),
        TextCase(
            "Step one, unplug it. Step two, wait ten seconds. Step three, plug it back in.",
            "1. Unplug it.\n2. Wait 10 seconds.\n3. Plug it back in."
        ),
        TextCase(
            "um, first, call the bank, uh, second, email Priya",
            "1. Call the bank\n2. Email Priya"
        ),
        TextCase(
            "One, buy twenty one stamps. Two, pay at two thirty.",
            "1. Buy 21 stamps.\n2. Pay at two thirty."
        ),
        TextCase("1, call the bank. 2, email Priya.", "1. Call the bank.\n2. Email Priya."),
        TextCase(
            "First, call the bank. Second, email Priya. Thanks everyone.",
            "1. Call the bank.\n2. Email Priya.\nThanks everyone."
        ),
    ]

    @Test(arguments: pipelineCases)
    func pipeline(_ c: TextCase) {
        #expect(full(c.input) == c.expected)
    }

    @Test(arguments: pipelineCases)
    func pipelineIsIdempotent(_ c: TextCase) {
        let once = full(c.input)
        #expect(full(once) == once)
    }

    @Test func replayHoldsThroughThePipeline() {
        let pipeline = TextPipeline()
        for c in Self.pipelineCases {
            let (_, trace) = pipeline.runTraced(TextPipelineInput(text: c.input))
            for stage in trace where stage.stage != "whitespace" {
                #expect(
                    TextTestSupport.replay(stage.edits, on: stage.input) == TextTestSupport.stripWhitespace(stage.output),
                    "stage \(stage.stage) of \(c.input.debugDescription)"
                )
            }
        }
    }

    @Test func optionTurnsItOff() {
        let text = "First, call the bank. Second, email Priya."
        let out = TextPipeline().run(TextPipelineInput(text: text, options: TextPipelineOptions(countedLists: false)))
        #expect(out.text == text)
    }

    @Test func stylesKeepTheListLines() {
        let text = "Three things. First, Call the bank. Second, Email Priya. Third, Book the flight."
        let casual = full(text, style: StylePreset.casual.options)
        let veryCasual = full(text, style: StylePreset.veryCasual.options)
        #expect(casual.contains("\n1. ") && casual.contains("\n2. ") && casual.contains("\n3. "))
        #expect(veryCasual.contains("\n1. ") && veryCasual.contains("\n2. ") && veryCasual.contains("\n3. "))
        // The list lines keep their final stops under casual (final-stop trimming skips list text).
        #expect(casual.hasSuffix("3. Book the flight."))
        #expect(veryCasual.lowercased() == veryCasual || veryCasual.contains("1. call the bank"))
        #expect(full(casual, style: StylePreset.casual.options) == casual)
        #expect(full(veryCasual, style: StylePreset.veryCasual.options) == veryCasual)
    }

    // MARK: Speed

    @Test func manyListsAreFast() {
        var text = ""
        for _ in 0..<500 {
            text += "I need two things. First, call the bank. Second, email Priya. Then we talk about something else. "
        }
        let clock = ContinuousClock()
        var out = StageResult(text: "")
        let elapsed = clock.measure { out = CountedLists().apply(text) }
        let ms = Double(elapsed.components.seconds) * 1000 + Double(elapsed.components.attoseconds) / 1e15
        print("COUNTEDLISTS-PERF 500 lists: \(ms) ms")
        #expect(out.text.contains("1. Call the bank."))
        #expect(ms < 3000, "took \(ms) ms")
    }
}
