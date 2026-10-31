import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct CardAccessibilityTests {
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
        #expect(finishedCopy.accessibilityLabel() == "Copied")
        #expect(!finishedCopy.isAccessibilityEnabled())
        #expect(!finishedCopy.accessibilityPerformPress())
        #expect(copied == 1)
    }
}
