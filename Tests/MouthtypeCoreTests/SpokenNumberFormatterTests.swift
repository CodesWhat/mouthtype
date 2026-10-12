import Testing
@testable import MouthtypeCore

@Suite struct SpokenNumberFormatterTests {
    private func format(_ text: String) -> StageResult {
        SpanRewriter.apply(SpokenNumberFormatter().spans(in: text), to: Array(text), stage: "number format")
    }

    static let convertCases: [TextCase] = [
        TextCase("I have twenty one apples", "I have 21 apples"),
        TextCase("I have twenty-one apples", "I have 21 apples"),
        TextCase("ten people came", "10 people came"),
        TextCase("eleven", "11"),
        TextCase("ninety nine problems", "99 problems"),
        TextCase("one hundred apples", "100 apples"),
        TextCase("two hundred and five apples", "205 apples"),
        TextCase("two hundred five apples", "205 apples"),
        TextCase("one thousand two hundred thirty four", "1234"),
        TextCase("twenty thousand", "20000"),
        TextCase("two thousand and twenty", "2020"),
        TextCase("three million five hundred thousand", "3500000"),
        TextCase("two million", "2000000"),
        TextCase("three point one four", "3.14"),
        TextCase("zero point five", "0.5"),
        TextCase("twenty point five", "20.5"),
        TextCase("fifty percent", "50%"),
        TextCase("one percent", "1%"),
        TextCase("twenty euros", "20 euros"),
        TextCase("two point five percent", "2.5%"),
        TextCase("a fifty percent chance", "a 50% chance"),
        TextCase("twenty dollars", "$20"),
        TextCase("one dollar", "$1"),
        TextCase("five dollars and fifty cents", "$5.50"),
        TextCase("five dollars and five cents", "$5.05"),
        TextCase("it costs twenty dollars today", "it costs $20 today"),
        TextCase("two thirty p m", "2:30 PM"),
        TextCase("two thirty pm", "2:30 PM"),
        TextCase("two thirty p.m.", "2:30 PM."),
        TextCase("meet at two thirty p.m. tomorrow", "meet at 2:30 PM tomorrow"),
        TextCase("at ten a m", "at 10 AM"),
        TextCase("at five p m.", "at 5 PM."),
        TextCase("twelve fifteen a m", "12:15 AM"),
        TextCase("seven oh five a m", "7:05 AM"),
        TextCase("eleven forty five p m", "11:45 PM"),
        TextCase("at five o'clock", "at 5:00"),
        TextCase("at five o\u{2019}clock", "at 5:00"),
        TextCase("one o'clock", "1:00"),
        TextCase("five o'clock p m", "5:00 PM"),
        TextCase("We need 3 boxes and twenty one more", "We need 3 boxes and 21 more"),
    ]

    @Test(arguments: convertCases)
    func converts(_ c: TextCase) {
        #expect(format(c.input).text == c.expected)
    }

    static let untouchedCases: [String] = [
        "one of them is here",
        "the one I want",
        "no one came",
        "I have one question",
        "number two",
        "I have two apples",
        "two or three",
        "one two three",
        "twenty twenty five",
        "five and ten",
        "a hundred people",
        "hundreds of people",
        "thousand",
        "twenty first",
        "the first of january",
        "january fifth",
        "my second thought",
        "give me a second",
        "five five five one two three four",
        "two thirty",
        "five fifty cents",
        "cents",
        "zero",
        "at one a man",
        "hello world",
        "",
        "点 二十一",
        "😀 twentyish 😀",
    ]

    @Test(arguments: untouchedCases)
    func leavesAlone(_ text: String) {
        let out = format(text)
        #expect(out.text == text)
        #expect(out.edits.isEmpty)
    }

    @Test func editLog() {
        let out = format("buy twenty one apples for five dollars and fifty cents")
        #expect(out.text == "buy 21 apples for $5.50")
        #expect(out.edits.count == 2)
        #expect(out.edits[0].stage == "number format")
        #expect(out.edits[0].kind == .replace)
        #expect(out.edits[0].fromText == "twenty one")
        #expect(out.edits[0].toText == "21")
        #expect(out.edits[0].wordDelta == -1)
        #expect(out.edits[0].position == 4)
        #expect(out.edits[1].fromText == "five dollars and fifty cents")
        #expect(out.edits[1].toText == "$5.50")
        #expect(out.edits[1].wordDelta == -4)
    }

    @Test func replayMatchesOutput() {
        for c in Self.convertCases {
            let out = format(c.input)
            #expect(
                TextTestSupport.replay(out.edits, on: c.input) == TextTestSupport.stripWhitespace(out.text),
                "replay failed for \(c.input.debugDescription)"
            )
        }
    }
}
