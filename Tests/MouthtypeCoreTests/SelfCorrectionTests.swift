import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SelfCorrectionTests {
    private func stage(_ text: String) -> String {
        SelfCorrection().apply(text).text
    }

    private func full(_ text: String) -> String {
        TextPipeline().run(TextPipelineInput(text: text)).text
    }

    static let positives: [TextCase] = [
        // The reported sentence, with and without the full stop.
        TextCase("Let's do coffee at two actually three.", "Let's do coffee at three."),
        TextCase("Let's do coffee at two actually three", "Let's do coffee at three"),
        TextCase("Let's do coffee at two, actually three.", "Let's do coffee at three."),
        TextCase("Let's do coffee at two, actually, three.", "Let's do coffee at three."),
        // Every cue.
        TextCase("Meet at three no wait four.", "Meet at four."),
        TextCase("Meet at three, no wait, four.", "Meet at four."),
        TextCase("Meet at three, no, wait, four.", "Meet at four."),
        TextCase("Meet at three no sorry four.", "Meet at four."),
        TextCase("Meet at three, sorry, four.", "Meet at four."),
        TextCase("Meet at three, I mean four.", "Meet at four."),
        TextCase("Meet at three or rather four.", "Meet at four."),
        TextCase("Meet at three, rather four.", "Meet at four."),
        TextCase("Meet at three, make that four.", "Meet at four."),
        TextCase("Meet at three, scratch that, four.", "Meet at four."),
        TextCase("Meet at three, no, four.", "Meet at four."),
        TextCase("Meet at three no four.", "Meet at four."),
        TextCase("Meet at three, wait, four.", "Meet at four."),
                TextCase("Meet at three, Actually four.", "Meet at four."),
        // Numbers: words, digits, tens, hundreds.
        TextCase("We need twenty one, actually twenty two chairs.", "We need twenty two chairs."),
        TextCase("We need twenty-one, actually twenty-five chairs.", "We need twenty-five chairs."),
        TextCase("We need 12 actually 15 chairs.", "We need 15 chairs."),
        TextCase("We need twelve, actually 15 chairs.", "We need 15 chairs."),
        TextCase("It's one hundred and five, I mean one hundred and fifteen.", "It's one hundred and fifteen."),
        TextCase("It weighs three point five, actually three point eight kilos.", "It weighs three point eight kilos."),
        TextCase("We have 1,200, actually 1,500 users.", "We have 1,500 users."),
        // Clock times.
        TextCase("Lunch at two thirty, actually three thirty.", "Lunch at three thirty."),
        TextCase("Lunch at two thirty p m, actually three thirty p m.", "Lunch at three thirty p m."),
        TextCase("Lunch at 2:30, actually 3:30.", "Lunch at 3:30."),
        TextCase("Lunch at 2:30 pm, no wait, 3:45 pm.", "Lunch at 3:45 pm."),
        TextCase("Lunch at five p m, actually six p m.", "Lunch at six p m."),
        TextCase("Lunch at five p.m., actually six p.m.", "Lunch at six p.m."),
        TextCase("Lunch at 5 pm, actually 6 pm.", "Lunch at 6 pm."),
        TextCase("Lunch at five o'clock, actually six o'clock.", "Lunch at six o'clock."),
        TextCase("Lunch at ten oh five, actually ten oh eight.", "Lunch at ten oh eight."),
        // Money and percent.
        TextCase("It costs twenty dollars, actually thirty dollars.", "It costs thirty dollars."),
        TextCase("It costs $20, I mean $30.", "It costs $30."),
        TextCase("It costs $20.50, actually $25.", "It costs $25."),
        TextCase("It costs 20 dollars, no, 30 dollars.", "It costs 30 dollars."),
        TextCase("Growth was ten percent, actually twelve percent.", "Growth was twelve percent."),
        TextCase("Growth was 10%, actually 12%.", "Growth was 12%."),
        TextCase("Growth was 10 percent, make that 12%.", "Growth was 12%."),
        // Weekdays and months.
        TextCase("Let's meet Monday, actually Tuesday.", "Let's meet Tuesday."),
        TextCase("Let's meet on Monday, I mean on Tuesday.", "Let's meet on Tuesday."),
        TextCase("Let's meet on Monday, I mean Tuesday.", "Let's meet on Tuesday."),
        TextCase("Let's meet on Monday no wait Friday.", "Let's meet on Friday."),
        TextCase("See you in March, actually April.", "See you in April."),
        TextCase("See you in March, actually in April.", "See you in April."),
        TextCase("It's due March fifth, actually March sixth.", "It's due March sixth."),
        TextCase("It's due on March fifth, actually March 6th.", "It's due on March 6th."),
        TextCase("It's due June 5, no wait, June 7.", "It's due June 7."),
        TextCase("It's due March twenty first, actually March twenty third.", "It's due March twenty third."),
        // Ordinals.
        TextCase("It's the fifth, actually the sixth.", "It's the sixth."),
        TextCase("It's on the fifth, actually sixth.", "It's on the sixth."),
        TextCase("It's the 5th, no wait, the 6th.", "It's the 6th."),
        TextCase("I finished first, actually second.", "I finished second."),
        // Sentence start capitalisation follows A.
        TextCase("Meet at twenty two, actually three.", "Meet at three."),
        TextCase("Two, actually three people came.", "Three people came."),
        // Several corrections in a row, and surrounding text left alone.
        TextCase("Meet at two, actually three, no wait, four.", "Meet at four."),
        TextCase("Call me at two, actually three, and bring the report.", "Call me at three, and bring the report."),
        TextCase("Hello there. Meet at two actually three. Bye.", "Hello there. Meet at three. Bye."),
        TextCase("Meet at two actually three and Monday no wait Tuesday.", "Meet at three and Tuesday."),
    ]

    @Test(arguments: positives)
    func resolvesTheCorrection(_ c: TextCase) {
        #expect(stage(c.input) == c.expected)
    }

    static let negatives: [String] = [
        "I actually enjoyed the movie.",
        "Two, actually, is enough.",
        "It is actually three.",
        "I have two, actually I have none.",
        "I have two, actually I have three.",
        "Meet at two, actually after lunch.",
        "From two to three.",
        "Two or three.",
        "Meet at two or rather late.",
        "At two and actually three people came.",
        "Did you get two? No, three of them left.",
        "I got two. Actually three.",
        "I got two; actually three.",
        "I got two... actually three.",
        "No, I don't want three.",
        "Wait for three.",
        "Sorry about Monday.",
        "I mean it, three times.",
        "Make that three.",
        "I said no to three.",
        "Please wait Tuesday.",
        "Step one, unplug it. Step two, wait ten seconds. Step three, plug it back in.",
        "Step two, wait ten seconds.",
        "Meet at three wait four.",
        // Different kinds do not mix.
        "Meet at two, actually Tuesday.",
        "It costs twenty dollars, no, thirty.",
        "Growth was ten percent, actually twelve.",
        "Lunch at two thirty, actually three.",
        "It's March fifth, actually the sixth.",
        "See you Monday, actually in April.",
        // A repeated preposition has to match the one before A.
        "Meet on two, actually at three.",
        "Meet at two, actually on Tuesday.",
        // Nothing to correct.
        "Two",
        "",
        "Meet at three.",
    ]

    @Test(arguments: negatives)
    func leavesTheTextAlone(_ text: String) {
        #expect(stage(text) == text)
    }

    @Test func logsOneEditUnderTheStageName() {
        let result = SelfCorrection().apply("Let's do coffee at two, actually three.")
        #expect(result.edits.count == 1)
        let edit = result.edits[0]
        #expect(edit.stage == "self-correction")
        #expect(edit.kind == .replace)
        #expect(edit.fromText == "two, actually three")
        #expect(edit.toText == "three")
        #expect(edit.wordDelta == -2)
        #expect(edit.position == 19)
    }

    @Test func theEditReplaysOntoTheInput() {
        let input = "Meet at two actually three and Monday no wait Tuesday."
        let result = SelfCorrection().apply(input)
        #expect(TextTestSupport.replay(result.edits, on: input) == TextTestSupport.stripWhitespace(result.text))
    }

    @Test func runsInThePipelineBeforeNumbersAndCountedLists() {
        #expect(full("Let's do coffee at two actually three.") == "Let's do coffee at three.")
        #expect(full("we have twenty one actually twenty two chairs") == "We have 22 chairs")
        let off = TextPipeline().run(TextPipelineInput(
            text: "Let's do coffee at two actually three.", options: TextPipelineOptions(selfCorrection: false)))
        #expect(off.text == "Let's do coffee at two actually three.")
        #expect(off.edits.allSatisfy { $0.stage != SelfCorrection.stageName })
    }

    @Test func seesSpokenCommandsOutput() {
        #expect(full("meet at two comma actually three") == "Meet at three")
    }

    @Test func theEditUsesTheStoreVocabulary() {
        let result = TextPipeline().run(TextPipelineInput(text: "Meet at two actually three."))
        #expect(result.edits.contains { $0.stage == "self-correction" })
    }
}
