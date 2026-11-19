import CoreGraphics
import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct PasteKeyLookupTests {
    private func layout(_ keys: [UInt16: String]) -> PasteKeyLookup.Translate { { keys[$0] } }

    @Test func qwertyTypesVOnKeyNine() {
        let qwerty = layout([0: "a", 9: "v", 11: "b"])
        #expect(PasteKeyLookup.keyCode(for: "v", current: qwerty, asciiCapable: { nil }) == 9)
    }

    @Test func aLayoutThatMovesVGivesItsOwnKey() {
        let moved = layout([9: "k", 47: "v"])
        #expect(PasteKeyLookup.keyCode(for: "v", current: moved, asciiCapable: { nil }) == 47)
    }

    @Test func aCommandTableThatKeepsQwertyPositionsIsHonoured() {
        // Dvorak - QWERTY: with Command held, the key at the QWERTY V position types v.
        let dvorakQwertyCommand = layout([9: "v", 40: "t"])
        #expect(PasteKeyLookup.keyCode(for: "v", current: dvorakQwertyCommand, asciiCapable: { nil }) == 9)
    }

    @Test func aMethodWithNoLayoutDataFallsBackToTheAsciiLayout() {
        let ascii = layout([9: "v"])
        #expect(PasteKeyLookup.keyCode(for: "v", current: nil, asciiCapable: { ascii }) == 9)
    }

    @Test func aLayoutWithDataButNoVDoesNotFallBack() {
        let cyrillic = layout([9: "м"])
        let ascii = layout([9: "v"])
        #expect(PasteKeyLookup.keyCode(for: "v", current: cyrillic, asciiCapable: { ascii }) == nil)
    }

    @Test func noLayoutAtAllResolvesNothing() {
        #expect(PasteKeyLookup.keyCode(for: "v", current: nil, asciiCapable: { nil }) == nil)
    }

    @Test func onlyKeyCodesBelow128AreTried() {
        #expect(PasteKeyLookup.keyCode(for: "v", current: layout([128: "v", 300: "v"]), asciiCapable: { nil }) == nil)
        #expect(PasteKeyLookup.keyCode(for: "v", current: layout([127: "v"]), asciiCapable: { nil }) == 127)
    }

    @Test func theLowestMatchingKeyWins() {
        #expect(PasteKeyLookup.keyCode(for: "v", current: layout([50: "v", 20: "v"]), asciiCapable: { nil }) == 20)
    }
}

@Suite struct PasteTargetPolicyTests {
    @Test func rolesThatCannotHoldTextAreRefused() {
        for role in [
            "AXButton", "AXMenuItem", "AXMenuBarItem", "AXCheckBox", "AXRadioButton", "AXImage", "AXSlider", "AXPopUpButton",
        ] {
            #expect(PasteTargetPolicy.refuses(role: role, textSettable: nil), "\(role)")
        }
    }

    @Test func rolesThatMightHoldTextAreLeftAlone() {
        for role in [
            "AXTextField", "AXTextArea", "AXComboBox", "AXWebArea", "AXGroup", "AXWindow", "AXScrollArea", "AXSearchField",
            "AXSomethingNew", "",
        ] {
            #expect(!PasteTargetPolicy.refuses(role: role, textSettable: false), "\(role)")
        }
    }

    @Test func noElementAndNoRolePasteAnyway() {
        #expect(!PasteTargetPolicy.refuses(role: nil, textSettable: nil))
    }

    @Test func staticTextIsRefusedOnlyWhenItsTextCannotBeSet() {
        #expect(PasteTargetPolicy.refuses(role: "AXStaticText", textSettable: false))
        #expect(!PasteTargetPolicy.refuses(role: "AXStaticText", textSettable: true))
        #expect(!PasteTargetPolicy.refuses(role: "AXStaticText", textSettable: nil))
    }
}

@Suite struct PasteVerifierTests {
    private typealias V = PasteVerifier

    private let base = FieldReading(value: "Hello", length: 5, selection: NSRange(location: 5, length: 0))
    private var baseline: V.Baseline { V.Baseline(reading: base, input: 7) }

    private func obs(
        _ reading: FieldReading?, same: Bool = true, input: UInt64? = 7
    ) -> V.Observation {
        V.Observation(reading: reading, focusSame: same, input: input)
    }

    private func judge(_ observations: [V.Observation], baseline: V.Baseline? = nil, pasted: String = " world") -> PasteVerdict {
        V.judge(baseline: baseline ?? self.baseline, pasted: pasted, observations: observations, expected: 3)
    }

    @Test func allThreeReadsUnchangedWithNoInputIsNotLanded() {
        #expect(judge([obs(base), obs(base), obs(base)]) == .notLanded)
    }

    @Test func aChangedValueWithoutThePastedTextIsNotConfirmed() {
        let changed = FieldReading(value: "Hello there", length: 5, selection: base.selection)
        #expect(judge([obs(base), obs(changed)]) == .unknown)
    }

    @Test func aChangedLengthConfirmsOnlyWhenTheFieldWasNotReadableBefore() {
        let unreadable = FieldReading(value: nil, length: 5, selection: base.selection)
        let changed = FieldReading(value: nil, length: 11, selection: base.selection)
        #expect(judge([obs(changed)], baseline: V.Baseline(reading: unreadable, input: 7)) == .confirmed)
        #expect(judge([obs(changed)]) == .unknown)
    }

    @Test func aMovedCaretConfirmsOnlyWhenTheFieldWasNotReadableBefore() {
        let unreadable = FieldReading(value: nil, length: 5, selection: base.selection)
        let moved = FieldReading(value: nil, length: 5, selection: NSRange(location: 3, length: 0))
        #expect(judge([obs(moved), obs(unreadable), obs(unreadable)], baseline: V.Baseline(reading: unreadable, input: 7)) == .confirmed)
        let valueOnly = FieldReading(value: "Hello", length: 5, selection: NSRange(location: 3, length: 0))
        #expect(judge([obs(valueOnly), obs(base), obs(base)]) == .unknown)
    }

    @Test(arguments: [nil, NSRange(location: 3, length: 2), NSRange(location: NSNotFound, length: 0)])
    func anUnreadableFieldNeedsAKnownCollapsedSelectionToConfirmAChange(selection: NSRange?) {
        let blind = V.Baseline(reading: FieldReading(value: nil, length: 5, selection: base.selection), input: 7)
        let changed = FieldReading(value: nil, length: 11, selection: selection)
        #expect(!V.confirms(obs(changed), baseline: blind, pasted: " world"))
        #expect(judge([obs(changed)], baseline: blind) == .unknown)
    }

    @Test func aReadableFieldMustGainThePastedTextToConfirm() {
        let landed = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(V.confirms(obs(landed), baseline: baseline, pasted: " world"))
        let other = FieldReading(value: "Hello there", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(!V.confirms(obs(other), baseline: baseline, pasted: " world"))
        #expect(!V.confirms(obs(nil), baseline: baseline, pasted: " world"))
    }

    @Test func repeatingTextTheFieldAlreadyHeldConfirmsOnlyWhenItAppearsAgain() {
        let held = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        let twice = FieldReading(value: "Hello world world", length: 17, selection: NSRange(location: 17, length: 0))
        let heldBaseline = V.Baseline(reading: held, input: 7)
        #expect(!V.confirms(obs(held), baseline: heldBaseline, pasted: " world"))
        #expect(V.confirms(obs(twice), baseline: heldBaseline, pasted: " world"))
    }

    @Test func whitespaceTheFieldRewritesDoesNotHideThePaste() {
        // A single-line input drops the newlines.
        let stripped = FieldReading(value: "Helloline oneline two", length: 21, selection: NSRange(location: 21, length: 0))
        #expect(V.confirms(obs(stripped), baseline: baseline, pasted: "\nline one\nline two"))
        // A web editor keeps words apart with no-break spaces and a zero-width space at the caret.
        let nbsp = FieldReading(value: "Hello\u{a0}new\u{a0}words\u{200b}", length: 16, selection: NSRange(location: 15, length: 0))
        #expect(V.confirms(obs(nbsp), baseline: baseline, pasted: " new words"))
        // A code editor indents each pasted line.
        let indented = FieldReading(value: "Hello\n    foo\n    bar", length: 21, selection: NSRange(location: 21, length: 0))
        #expect(V.confirms(obs(indented), baseline: baseline, pasted: "\nfoo\nbar"))
        // The stripped text still has to be the paste.
        let other = FieldReading(value: "Hellosomething else", length: 19, selection: NSRange(location: 19, length: 0))
        #expect(!V.confirms(obs(other), baseline: baseline, pasted: "\nline one\nline two"))
    }

    @Test func pastingOverASelectionThatHeldTheSameTextIsNotConfirmedByTheCaretAlone() {
        let selected = V.Baseline(reading: FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 6, length: 5)), input: 7)
        // The text reads exactly as before. A real paste leaves it like this, but so does an app that ignores the paste
        // and collapses the selection itself, so it stays unknown and no Return goes out.
        let same = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(!V.confirms(obs(same), baseline: selected, pasted: "world"))
        #expect(V.judge(baseline: selected, pasted: "world", observations: [obs(same), obs(same), obs(same)], expected: 3) == .unknown)
        // The previous clipboard landing over the selection instead is a change of the same size, and not the paste.
        let other = FieldReading(value: "Hello hunter2", length: 13, selection: NSRange(location: 13, length: 0))
        #expect(!V.confirms(obs(other), baseline: selected, pasted: "world"))
        #expect(V.judge(baseline: selected, pasted: "world", observations: [obs(other), obs(other), obs(other)], expected: 3) == .unknown)
    }

    @Test func anUnchangedFieldOverASelectionThatHeldTheSameTextIsNotConfirmed() {
        let selected = V.Baseline(reading: FieldReading(value: "hello", length: 5, selection: NSRange(location: 0, length: 5)), input: 7)
        let ignored = obs(selected.reading)
        #expect(!V.confirms(ignored, baseline: selected, pasted: "hello"))
        // Nothing at all changed, so the usual rule for an untouched field applies.
        #expect(V.judge(baseline: selected, pasted: "hello", observations: [ignored, ignored, ignored], expected: 3) == .notLanded)
        // The caret collapsed after the text used to confirm. It no longer does: the text is exactly what it was, and
        // an app that ignored the paste can move the caret there on its own.
        let landed = FieldReading(value: "hello", length: 5, selection: NSRange(location: 5, length: 0))
        #expect(!V.confirms(obs(landed), baseline: selected, pasted: "hello"))
        #expect(V.judge(baseline: selected, pasted: "hello", observations: [obs(landed), obs(landed), obs(landed)], expected: 3) == .unknown)
        #expect(!V.confirms(obs(landed, input: 8), baseline: selected, pasted: "hello"))
        #expect(!V.confirms(obs(landed, same: false), baseline: selected, pasted: "hello"))
        for selection in [NSRange(location: 0, length: 0), NSRange(location: 3, length: 0), NSRange(location: 1, length: 4)] {
            let elsewhere = FieldReading(value: "hello", length: 5, selection: selection)
            #expect(!V.confirms(obs(elsewhere), baseline: selected, pasted: "hello"))
        }
    }

    @Test func anIgnoredPasteThatOnlyCollapsesTheSelectionIsNotConfirmed() {
        // "hello " is selected and "hello" pasted. The app ignores it but drops the selection to the end.
        let selected = V.Baseline(reading: FieldReading(value: "hello ", length: 6, selection: NSRange(location: 0, length: 6)), input: 7)
        let collapsed = FieldReading(value: "hello ", length: 6, selection: NSRange(location: 6, length: 0))
        #expect(!V.confirms(obs(collapsed), baseline: selected, pasted: "hello"))
        #expect(V.judge(baseline: selected, pasted: "hello", observations: [obs(collapsed), obs(collapsed), obs(collapsed)], expected: 3) == .unknown)
        #expect(!V.confirms(obs(selected.reading), baseline: selected, pasted: "hello"))
    }

    @Test func aPasteThatOnlyChangesWhitespaceConfirmsByItsCaret() {
        // A single-line field drops the newline: the text differs from before only in whitespace, and the caret ends at
        // 10 though the pasted text is 11 long.
        let selected = V.Baseline(reading: FieldReading(value: "hello world", length: 11, selection: NSRange(location: 0, length: 11)), input: 7)
        let landed = FieldReading(value: "helloworld", length: 10, selection: NSRange(location: 10, length: 0))
        #expect(V.confirms(obs(landed), baseline: selected, pasted: "hello\nworld"))
        #expect(V.judge(baseline: selected, pasted: "hello\nworld", observations: [obs(landed)], expected: 3) == .confirmed)
        #expect(!V.confirms(obs(landed, input: 8), baseline: selected, pasted: "hello\nworld"))
        let elsewhere = FieldReading(value: "helloworld", length: 10, selection: NSRange(location: 4, length: 0))
        #expect(!V.confirms(obs(elsewhere), baseline: selected, pasted: "hello\nworld"))
        // The same paste over a field that already read "helloworld" leaves the text exactly as it was, so it can't confirm.
        let exact = V.Baseline(reading: FieldReading(value: "helloworld", length: 10, selection: NSRange(location: 0, length: 10)), input: 7)
        #expect(!V.confirms(obs(landed), baseline: exact, pasted: "hello\nworld"))
        #expect(!V.confirms(obs(exact.reading), baseline: exact, pasted: "hello\nworld"))
    }

    @Test func aCaretAlreadyWhereAnEmptyPasteWouldLeaveItProvesNothing() {
        let collapsed = V.Baseline(reading: FieldReading(value: "hello", length: 5, selection: NSRange(location: 5, length: 0)), input: 7)
        #expect(!V.confirms(obs(collapsed.reading), baseline: collapsed, pasted: ""))
    }

    @Test func aFieldThatSwapsQuotesStillConfirmsByWhatItGained() {
        let pasted = "the report she called \"final\" went out this morning"
        let curly = FieldReading(
            value: "Hellothe report she called \u{201c}final\u{201d} went out this morning", length: 56, selection: NSRange(location: 56, length: 0))
        #expect(V.confirms(obs(curly), baseline: baseline, pasted: pasted))
        // Typing in between could have put it there.
        #expect(!V.confirms(obs(curly, input: 8), baseline: baseline, pasted: pasted))
        // Too many characters differ for the gain to be the paste.
        let rewritten = FieldReading(
            value: "HelloTHE REPORT she called \u{201c}final\u{201d} went out this morning", length: 56, selection: NSRange(location: 56, length: 0))
        #expect(!V.confirms(obs(rewritten), baseline: baseline, pasted: pasted))
    }

    @Test func aShortTranscriptInsideAWronglyPastedLongerClipboardDoesNotConfirm() {
        // The target pasted the user's previous clipboard, which happens to contain the transcript.
        let wrong = FieldReading(
            value: "Hellothe meeting notes say ok and nothing else", length: 46, selection: NSRange(location: 46, length: 0))
        #expect(!V.confirms(obs(wrong), baseline: baseline, pasted: "ok"))
        // The transcript itself, landing as a short gain, still confirms.
        let landed = FieldReading(value: "Hello ok", length: 8, selection: NSRange(location: 8, length: 0))
        #expect(V.confirms(obs(landed), baseline: baseline, pasted: " ok"))
    }

    @Test func lengthChangingPunctuationRewritesStayUnconfirmed() {
        let pasted = "wait... then... -- go -- now"
        let rewrittenValue = "Hellowait… then… — go — now"
        let rewritten = FieldReading(
            value: rewrittenValue, length: rewrittenValue.utf16.count, selection: NSRange(location: rewrittenValue.utf16.count, length: 0))
        #expect(judge([obs(rewritten)], pasted: pasted) == .unknown)
        let exactValue = "Hello" + pasted
        let exact = FieldReading(
            value: exactValue, length: exactValue.utf16.count, selection: NSRange(location: exactValue.utf16.count, length: 0))
        #expect(V.confirms(obs(exact), baseline: baseline, pasted: pasted))
    }

    @Test func gainingSomethingElseOfTheSameLengthDoesNotConfirm() {
        let secret = FieldReading(value: "Hellosecret", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(!V.confirms(obs(secret), baseline: baseline, pasted: "send it"))
        #expect(!V.confirms(obs(secret), baseline: baseline, pasted: "sendit"))
        let judged = judge([obs(secret), obs(secret), obs(secret)], pasted: "send it")
        #expect(judged == .unknown)
    }

    @Test func aTruncatedPasteDoesNotConfirm() {
        let cut = FieldReading(value: "Hellosend the full", length: 18, selection: NSRange(location: 18, length: 0))
        #expect(!V.confirms(obs(cut), baseline: baseline, pasted: "send the full report"))
    }

    @Test func anUnreadableBaselineConfirmsOnRewrittenWhitespaceOrAnyQuietChange() {
        let blind = V.Baseline(reading: FieldReading(value: nil, length: 5, selection: base.selection), input: 7)
        let shown = FieldReading(value: "Hello\u{a0}world", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(V.confirms(obs(shown), baseline: blind, pasted: " world"))
        let grew = FieldReading(value: nil, length: 11, selection: NSRange(location: 11, length: 0))
        #expect(V.confirms(obs(grew), baseline: blind, pasted: " world"))
        #expect(!V.confirms(obs(grew, input: 8), baseline: blind, pasted: " world"))
    }

    @Test func compactingDropsEveryKindOfSpace() {
        #expect(V.compact(" a\tb\nc\r\nd\u{a0}e\u{2003}f\u{200b}g\u{feff}") == "abcdefg")
        #expect(V.compact("👩🏽‍💻 ok") == V.compact("👩🏽‍💻ok"))
    }

    @Test func aValueContainingThePastedTextConfirmsEvenWithTypingInBetween() {
        let landed = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        #expect(judge([obs(landed, input: 9)]) == .confirmed)
    }

    @Test func textTheFieldAlreadyHeldDoesNotConfirm() {
        let held = FieldReading(value: "Hello world", length: 11, selection: NSRange(location: 11, length: 0))
        let verdict = V.judge(
            baseline: V.Baseline(reading: held, input: 7), pasted: " world", observations: [obs(held), obs(held), obs(held)],
            expected: 3
        )
        #expect(verdict == .notLanded)
    }

    @Test func aChangeWithInputInBetweenIsNotConfirmedByTheChangeAlone() {
        let typed = FieldReading(value: "Hellox", length: 6, selection: NSRange(location: 6, length: 0))
        #expect(judge([obs(typed, input: 8), obs(typed, input: 8), obs(typed, input: 8)]) == .unknown)
    }

    @Test func inputInBetweenIsUnknownEvenWhenNothingChanged() {
        #expect(judge([obs(base), obs(base, input: 8), obs(base, input: 8)]) == .unknown)
    }

    @Test func anUnknownInputCountIsUnknown() {
        #expect(judge([obs(base, input: nil), obs(base, input: nil), obs(base, input: nil)]) == .unknown)
        #expect(judge([obs(base), obs(base), obs(base)], baseline: V.Baseline(reading: base, input: nil)) == .unknown)
    }

    @Test func focusMovingIsUnknown() {
        #expect(judge([obs(base), obs(nil, same: false), obs(nil, same: false)]) == .unknown)
        #expect(judge([obs(base), obs(base, same: false), obs(base)]) == .unknown)
    }

    @Test func anUnreadableFieldIsUnknown() {
        let partial = FieldReading(value: "Hello", length: nil, selection: base.selection)
        #expect(judge([obs(base), obs(partial), obs(base)]) == .unknown)
        #expect(judge([obs(nil), obs(nil), obs(nil)]) == .unknown)
        let blind = V.Baseline(reading: FieldReading(), input: 7)
        #expect(judge([obs(FieldReading()), obs(FieldReading()), obs(FieldReading())], baseline: blind) == .unknown)
    }

    @Test func noBaselineIsUnknown() {
        #expect(V.judge(baseline: nil, pasted: "x", observations: [], expected: 3) == .unknown)
    }

    @Test func fewerReadsThanPlannedIsNeverNotLanded() {
        #expect(judge([obs(base), obs(base)]) == .unknown)
    }

    @Test func onlyNotLandedHasACard() {
        #expect(DeliveryCard.forVerdict(.notLanded, transcript: "x") == .notLanded("x"))
        #expect(DeliveryCard.forVerdict(.confirmed, transcript: "x") == nil)
        #expect(DeliveryCard.forVerdict(.unknown, transcript: "x") == nil)
        #expect(PasteVerdict.confirmed.storeOutcome == "confirmed" && PasteVerdict.notLanded.storeOutcome == "not landed")
    }
}
