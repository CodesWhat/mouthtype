// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Testing
@testable import MouthtypeMac

@Suite struct InsertionSpacingTests {
    private func spaced(_ text: String, after before: TextBeforeCursor = .unknown) -> String {
        Spacing.spaced(text, before: before)
    }

    @Test func neverAddsATrailingSpace() {
        #expect(spaced("Hello world.") == "Hello world.")
        #expect(spaced("Next", after: .start) == "Next")
        #expect(spaced("Hello. ") == "Hello. ")
        #expect(spaced("world", after: .character("o")) == " world")
    }

    @Test func leadingSpaceAfterAWordOrPunctuation() {
        #expect(spaced("world", after: .character("o")) == " world")
        #expect(spaced("apples", after: .character("3")) == " apples")
        #expect(spaced("Next", after: .character(".")) == " Next")
    }

    @Test func noLeadingSpaceAfterWhitespaceStartOrUnknown() {
        for before: TextBeforeCursor in [.character(" "), .character("\n"), .character("\t"), .start, .unknown] {
            #expect(spaced("Next", after: before) == "Next")
        }
    }

    @Test func noLeadingSpaceAfterAnOpener() {
        for opener: Character in ["(", "[", "\"", "“", "¿", "/", "@"] {
            #expect(spaced("next", after: .character(opener)) == "next")
        }
    }

    @Test func noLeadingSpaceBeforeAttachingPunctuation() {
        #expect(spaced(", and then", after: .character("o")) == ", and then")
        #expect(spaced("?", after: .character("o")) == "?")
    }

    @Test func noSpacesInChineseOrJapanese() {
        #expect(spaced("你好。", after: .character("。")) == "你好。")
        #expect(spaced("こんにちは", after: .character("す")) == "こんにちは")
        #expect(spaced("你好", after: .character("a")) == "你好")
    }

    @Test func emptyStaysEmpty() {
        #expect(spaced("", after: .character("o")) == "")
    }

    @Test func listsStartOnTheirOwnLineWithNoSpaceBeforeTheMarker() {
        #expect(spaced("- Milk\n- Eggs", after: .character("o")) == "\n- Milk\n- Eggs")
        #expect(spaced("1. Milk\n2. Eggs", after: .character(".")) == "\n1. Milk\n2. Eggs")
        #expect(spaced("- Milk", after: .character("\n")) == "- Milk")
        #expect(spaced("- Milk", after: .start) == "- Milk")
        #expect(spaced("- Milk", after: .unknown) == "- Milk")
    }

    @Test func aLeadingNewlineGetsNoSpace() {
        #expect(spaced("\nNext", after: .character("o")) == "\nNext")
    }

    @Test func plainTextThatLooksSimilarStillGetsItsSpace() {
        #expect(spaced("-5 degrees", after: .character("o")) == " -5 degrees")
        #expect(spaced("2.5 million", after: .character("o")) == " 2.5 million")
    }

    @Test func listDetection() {
        #expect(Spacing.startsList("- a") && Spacing.startsList("12. a"))
        #expect(!Spacing.startsList("-a") && !Spacing.startsList("1.5") && !Spacing.startsList(". a") && !Spacing.startsList(""))
    }
}
