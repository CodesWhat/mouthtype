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

    @Test func aChangedValueConfirms() {
        let changed = FieldReading(value: "Hello there", length: 5, selection: base.selection)
        #expect(judge([obs(base), obs(changed)]) == .confirmed)
    }

    @Test func aChangedLengthConfirms() {
        let changed = FieldReading(value: nil, length: 11, selection: base.selection)
        #expect(judge([obs(changed)]) == .confirmed)
    }

    @Test func aMovedCaretConfirms() {
        let changed = FieldReading(value: "Hello", length: 5, selection: NSRange(location: 3, length: 0))
        #expect(judge([obs(changed), obs(base), obs(base)]) == .confirmed)
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
