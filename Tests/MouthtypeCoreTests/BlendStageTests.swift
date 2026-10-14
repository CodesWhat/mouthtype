import Testing
@testable import MouthtypeCore

@Suite struct BlendStageTests {
    private func blend(_ text: String, before: String? = nil, after: String? = nil, context: Bool = true, protected: Set<String> = []) -> String {
        let ctx: InsertionContext? = context ? InsertionContext(before: before, after: after) : nil
        return BlendStage(context: ctx, protectedWords: protected).apply(text).text
    }

    // MARK: Mid-sentence

    @Test(arguments: [
        TextCase("The deck is ready", "the deck is ready"),
        TextCase("Then we ship", "then we ship"),
        TextCase("A new approach", "a new approach"),
    ])
    func lowercasesAfterMidSentenceBefore(_ c: TextCase) {
        #expect(blend(c.input, before: "I think") == c.expected)
        #expect(blend(c.input, before: "I think ") == c.expected)
        #expect(blend(c.input, before: "first,") == c.expected)
        #expect(blend(c.input, before: "first;") == c.expected)
        #expect(blend(c.input, before: "room 12") == c.expected)
    }

    @Test(arguments: ["I think so", "I'm sure", "I'll go", "I've seen", "I'd say", "I\u{2019}m sure", "NASA launched", "API docs", "iPhone is out", "McDonald is open"])
    func keepsExceptionsMidSentence(_ text: String) {
        #expect(blend(text, before: "and then") == text)
    }

    @Test func keepsAProtectedWord() {
        #expect(blend("Mouthtype is great", before: "I think", protected: ["Mouthtype"]) == "Mouthtype is great")
        #expect(blend("Mouthtype is great", before: "I think") == "mouthtype is great")
    }

    @Test func newlineBetweenBeforeAndCursorStartsAFreshSentence() {
        #expect(blend("the deck", before: "Hello\n") == "The deck")
        #expect(blend("the deck", before: "Hello\n  ") == "The deck")
    }

    // MARK: Sentence start / no context

    @Test(arguments: [
        TextCase("the deck is ready", "The deck is ready"),
        TextCase("so I think", "So I think"),
        TextCase("i think", "I think"),
        TextCase("éclair time", "Éclair time"),
        TextCase("iPhone is out", "iPhone is out"),
        TextCase("eBay sells", "eBay sells"),
        TextCase("Already fine", "Already fine"),
        TextCase("2 PM works", "2 PM works"),
        TextCase("\"quoted\" start", "\"quoted\" start"),
        TextCase("你好 world", "你好 world"),
        TextCase("😀 hello", "😀 hello"),
    ])
    func capitalisesWithNoContext(_ c: TextCase) {
        #expect(blend(c.input, context: false) == c.expected)
        #expect(blend(c.input, before: nil) == c.expected)
        #expect(blend(c.input, before: "") == c.expected)
        #expect(blend(c.input, before: "Done. ") == c.expected)
        #expect(blend(c.input, before: "Done?") == c.expected)
    }

    @Test func protectedWordIsNotCapitalised() {
        #expect(blend("npm install", context: false, protected: ["npm"]) == "npm install")
        #expect(blend("npm install", context: false) == "Npm install")
    }

    @Test func otherBeforeEndingsLeaveCasingAlone() {
        #expect(blend("the deck", before: "he said (") == "the deck")
        #expect(blend("The deck", before: "he said (") == "The deck")
    }

    // MARK: Trailing full stop

    @Test func dropsTrailingStopBeforeFollowingText() {
        #expect(blend("send it.", before: "please ", after: "now") == "send it")
        #expect(blend("send it.", before: "please", after: " now") == "send it")
        #expect(blend("send it.", before: "please", after: "") == "send it.")
        #expect(blend("send it.", before: "please", after: nil) == "send it.")
        #expect(blend("send it.", before: "please", after: "\nnext") == "send it.")
    }

    @Test func onlyAFullStopIsDropped() {
        #expect(blend("is it?", before: "so", after: "x") == "is it?")
        #expect(blend("wait...", before: "so", after: "x") == "wait...")
        #expect(blend("wait…", before: "so", after: "x") == "wait…")
        #expect(blend("done.  ", before: "so", after: "x") == "done  ")
    }

    // MARK: Logging

    @Test func logsCaseChanges() {
        let out = BlendStage(context: InsertionContext(before: "and", after: nil)).apply("Then we go")
        #expect(out.edits.count == 1)
        #expect(out.edits[0].stage == "blend")
        #expect(out.edits[0].kind == .replace)
        #expect(out.edits[0].fromText == "Then")
        #expect(out.edits[0].toText == "then")
        #expect(out.edits[0].wordDelta == 0)
        #expect(out.edits[0].position == 0)
    }

    @Test func logsDroppedStop() {
        let out = BlendStage(context: InsertionContext(before: "and", after: "x")).apply("then we go.")
        #expect(out.text == "then we go")
        #expect(out.edits.count == 1)
        #expect(out.edits[0].kind == .delete)
        #expect(out.edits[0].fromText == ".")
        #expect(out.edits[0].position == 10)
    }

    @Test func emptyTextIsEmpty() {
        #expect(blend("", before: "and") == "")
    }

    @Test func firstWordsHelper() {
        #expect(BlendStage.firstWords(of: ["Mouthtype", "Dear Scott,", "", "  iPhone 15"]) == ["Mouthtype", "Dear", "iPhone"])
    }
}
