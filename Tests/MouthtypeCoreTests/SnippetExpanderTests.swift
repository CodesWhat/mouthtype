import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct SnippetExpanderTests {
    private let now = Date(timeIntervalSince1970: 1_791_763_200)  // 2026-10-12 00:00 UTC
    private let fixedDate: SnippetExpander.DateFormatter = { _ in "October 12, 2026" }

    private func expander(_ snippets: [Snippet], clipboard: String? = nil) -> SnippetExpander {
        SnippetExpander(snippets: snippets, now: now, clipboard: clipboard, dateFormatter: fixedDate)
    }

    @Test func matchingTriggersIncludeIdenticalReplacementsAndRespectBoundaries() {
        let e = expander([
            Snippet(trigger: "my email", expansion: "my email"),
            Snippet(trigger: "email", expansion: "elsewhere"),
        ])
        #expect(e.matchingTriggers(in: "my email, MY EMAIL and emails") == ["my email", "my email"])
        #expect(e.apply("my email").edits.isEmpty)
    }

    @Test func triggerAloneExpands() {
        let s = expander([Snippet(trigger: "my address", expansion: "1 Main St, Springfield")])
        #expect(s.apply("my address").text == "1 Main St, Springfield")
        #expect(s.apply("My Address").text == "1 Main St, Springfield")
    }

    @Test func triggerInsideASentence() {
        let s = expander([Snippet(trigger: "my address", expansion: "1 Main St")])
        #expect(s.apply("send it to my address please").text == "send it to 1 Main St please")
    }

    @Test func punctuationStaysOutside() {
        let s = expander([Snippet(trigger: "my address", expansion: "1 Main St")])
        #expect(s.apply("Send it to my address.").text == "Send it to 1 Main St.")
        #expect(s.apply("My address, please").text == "1 Main St, please")
        #expect(s.apply("(my address)").text == "(1 Main St)")
    }

    @Test func wholeWordOnly() {
        let s = expander([Snippet(trigger: "sig", expansion: "Best, Scott")])
        #expect(s.apply("a signature").text == "a signature")
        #expect(s.apply("add my sig now").text == "add my Best, Scott now")
    }

    @Test func longestTriggerWins() {
        let s = expander([
            Snippet(trigger: "my email", expansion: "SHORT"),
            Snippet(trigger: "my email address", expansion: "LONG"),
        ])
        #expect(s.apply("use my email address now").text == "use LONG now")
        #expect(s.apply("use my email now").text == "use SHORT now")
    }

    @Test func expansionIsNeverRescanned() {
        let s = expander([
            Snippet(trigger: "alpha", expansion: "beta"),
            Snippet(trigger: "beta", expansion: "gamma"),
        ])
        #expect(s.apply("alpha beta").text == "beta gamma")
    }

    @Test func dateVariableUsesTheInjectedFormatter() {
        let s = expander([Snippet(trigger: "today", expansion: "Date: {date}.")])
        #expect(s.apply("today").text == "Date: October 12, 2026.")
        #expect(expander([Snippet(trigger: "d", expansion: "{DATE}")]).apply("d").text == "October 12, 2026")
    }

    @Test func defaultFormatterIsLongStyleInTheCurrentLocale() {
        let s = SnippetExpander(snippets: [Snippet(trigger: "d", expansion: "{date}")], now: now, clipboard: nil)
        let expected = now.formatted(Date.FormatStyle(date: .long, time: .omitted).locale(Locale.current))
        #expect(s.apply("d").text == expected)
        #expect(!expected.isEmpty)
    }

    @Test func clipboardVariable() {
        let s = expander([Snippet(trigger: "paste link", expansion: "See {clipboard} for details")], clipboard: "https://x.test")
        let out = s.apply("paste link")
        #expect(out.text == "See https://x.test for details")
        #expect(out.notes.isEmpty)
    }

    @Test func missingClipboardExpandsToEmptyAndIsLogged() {
        let s = expander([Snippet(trigger: "paste link", expansion: "See {clipboard} for details")], clipboard: nil)
        let out = s.apply("paste link")
        #expect(out.text == "See  for details")
        #expect(out.notes.count == 1)
        #expect(out.notes[0].contains("paste link"))
    }

    @Test func clipboardTextIsNotRescannedForVariablesOrTriggers() {
        let s = expander(
            [Snippet(trigger: "paste", expansion: "{clipboard}"), Snippet(trigger: "secret", expansion: "X")],
            clipboard: "{date} secret"
        )
        #expect(s.apply("paste").text == "{date} secret")
    }

    @Test func unknownBracesAreLiteral() {
        let s = expander([Snippet(trigger: "code", expansion: "func f() { return {x} }")])
        #expect(s.apply("code").text == "func f() { return {x} }")
    }

    @Test func emptyTriggerIsIgnored() {
        let s = expander([Snippet(trigger: "  ", expansion: "X")])
        #expect(s.apply("a b").text == "a b")
    }

    @Test func logsTheExpansion() {
        let s = expander([Snippet(trigger: "my address", expansion: "1 Main St")])
        let out = s.apply("send it to my address.")
        #expect(out.edits.count == 1)
        let e = out.edits[0]
        #expect(e.stage == "snippet")
        #expect(e.kind == .replace)
        #expect(e.fromText == "my address")
        #expect(e.toText == "1 Main St")
        #expect(e.wordDelta == 1)
        #expect(e.position == 11)
    }

    @Test func multilineExpansion() {
        let s = expander([Snippet(trigger: "sign off", expansion: "Thanks,\nScott")])
        #expect(s.apply("ok sign off").text == "ok Thanks,\nScott")
    }

    @Test func unicodeTriggers() {
        let s = expander([Snippet(trigger: "café order", expansion: "Flat white")])
        #expect(s.apply("un café order, s'il vous plaît").text == "un Flat white, s'il vous plaît")
        #expect(s.apply("东京 café order 😀").text == "东京 Flat white 😀")
    }
}
