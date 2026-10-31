import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct CardAccessibilityTests {
    @Test(arguments: [CardStyle.classic, .glass, .matrix, .minimal])
    func renderedUndoExposesItsCurrentCountdownAndPressAction(style: CardStyle) throws {
        _ = NSApplication.shared
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: style, scale: .standard, embedded: false)
        var undone = 0
        view.onAction = { if $0 == .undo { undone += 1 } }
        view.render(CardViewState(card: .cancelled()), typography: Typography.current())
        func buttons(_ root: NSView) -> [CardButtonView] {
            root.subviews.flatMap { child in (child as? CardButtonView).map { [$0] } ?? buttons(child) }
        }
        let undo = try #require(buttons(view).first)
        #expect(undo.accessibilityRole() == .button)
        #expect(undo.accessibilityLabel()?.hasPrefix("Undo ") == true)
        #expect(undo.accessibilityLabel() == undo.label.string)
        #expect(undo.isAccessibilityEnabled())
        #expect(undo.accessibilityPerformPress())
        #expect(undone == 1)
    }

    @Test(arguments: [CardStyle.classic, .glass, .matrix, .minimal])
    func completedSpellingButtonsKeepTheirAccessibleIdentity(style: CardStyle) throws {
        _ = NSApplication.shared
        let pair = SpellingPair(heard: "name", corrected: "Name")
        for (card, label) in [(DeliveryCard.rememberSpelling(pair), "Saved"), (.forgetSpelling(pair), "Forgotten")] {
            let view = DeliveryCardView(frame: .zero)
            view.configure(style: style, scale: .standard, embedded: false)
            func buttons(_ root: NSView) -> [CardButtonView] {
                root.subviews.flatMap { child in (child as? CardButtonView).map { [$0] } ?? buttons(child) }
            }
            view.render(CardViewState(card: card), typography: Typography.current())
            let original = try #require(buttons(view).first)
            var completed = CardViewState(card: card)
            completed.copied = true
            view.render(completed, typography: Typography.current())
            let finished = try #require(buttons(view).first)
            #expect(finished === original)
            #expect(original.accessibilityLabel() == label)
            #expect(!original.isAccessibilityEnabled())
            #expect(!original.accessibilityPerformPress())
            view.render(CardViewState(card: .secure("Another take")), typography: Typography.current())
            #expect(try #require(buttons(view).first) !== original)
            #expect(original.superview == nil)
        }
    }

    @Test(arguments: [CardStyle.classic, .glass, .matrix, .minimal])
    func renderedControlsExposeLabelsAndPressActions(style: CardStyle) throws {
        _ = NSApplication.shared
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: style, scale: .standard, embedded: false)
        var copied = 0
        var dismissed = 0
        view.onAction = { if $0 == .copy { copied += 1 } }
        view.onDismiss = { dismissed += 1 }
        view.render(CardViewState(card: .pasteFailed("Keep this text.")), typography: Typography.current())
        func descendants(_ root: NSView) -> [NSView] {
            root.subviews.flatMap { [$0] + descendants($0) }
        }
        let copy = try #require(descendants(view).compactMap { $0 as? CardButtonView }.first)
        let close = try #require(descendants(view).compactMap { $0 as? CardDismissView }.first)
        #expect(copy.isAccessibilityElement())
        #expect(copy.accessibilityRole() == .button)
        #expect(copy.accessibilityLabel() == "Copy")
        #expect(copy.accessibilityPerformPress())
        #expect(copied == 1)
        #expect(close.accessibilityRole() == .button)
        #expect(close.accessibilityLabel() == "Dismiss")
        #expect(close.accessibilityPerformPress())
        #expect(dismissed == 1)
        var completed = CardViewState(card: .pasteFailed("Keep this text."))
        completed.copied = true
        view.render(completed, typography: Typography.current())
        let finishedCopy = try #require(descendants(view).compactMap { $0 as? CardButtonView }.first)
        #expect(finishedCopy === copy)
        #expect(finishedCopy.accessibilityLabel() == "Copied")
        #expect(!finishedCopy.isAccessibilityEnabled())
        #expect(!finishedCopy.accessibilityPerformPress())
        #expect(copied == 1)
    }
}
