import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
private final class FakeSurface: CardSurface {
    var states: [CardViewState?] = []
    func render(_ state: CardViewState?) { states.append(state) }
    var visible: CardViewState? { states.last ?? nil }
}

@MainActor
private final class FakeClipboard: ClipboardWriting {
    var written: [String] = []
    func write(_ text: String) { written.append(text) }
}

@MainActor
@Suite struct CardLayoutTests {
    typealias C = CardLayout

    private func input(
        transcript: CGFloat? = nil, lines: CGFloat = 18, header: CGFloat = 16, labels: [CGFloat] = [28], bar: Bool = false
    ) -> C.Input {
        C.Input(
            headerTextHeight: header, headerLineHeight: 16, transcriptTextHeight: transcript, transcriptLineHeight: lines,
            buttonLabelWidths: labels, hasCountdownBar: bar
        )
    }

    @Test func aShortTranscriptGrowsTheCardAndNeverScrolls() {
        let one = C.make(input(transcript: 18))
        let three = C.make(input(transcript: 54))
        #expect(one.transcript?.height == 18 && three.transcript?.height == 54)
        #expect(!one.transcriptScrolls && !three.transcriptScrolls)
        #expect(three.size.height - one.size.height == 36)
        #expect(one.size.width == 224)
    }

    @Test func theTranscriptGrowsToFiveLinesThenScrollsInside() {
        let five = C.make(input(transcript: 90))
        #expect(five.transcript?.height == 90 && !five.transcriptScrolls)
        let long = C.make(input(transcript: 400))
        #expect(long.transcript?.height == 90 && long.transcriptScrolls)
        #expect(long.size.height == five.size.height)
        #expect(C.make(input(transcript: 91)).transcriptScrolls)
    }

    @Test func aCardWithNoTranscriptIsJustTheHeaderAndButtons() {
        let frames = C.make(input(transcript: nil, labels: [28], bar: true))
        #expect(frames.transcript == nil && frames.bar != nil)
        let expected = C.insets.top + C.rowHeight + C.transcriptBottom + C.buttonHeight + C.insets.bottom
        #expect(frames.size.height == expected)
        #expect(C.make(input(transcript: nil, labels: [28], bar: false)).size.height == expected)
    }

    @Test func theCountdownBarLiesFlushAlongTheBottomEdgeBelowTheButton() throws {
        let f = C.make(input(transcript: nil, labels: [28], bar: true))
        let bar = try #require(f.bar)
        #expect(bar.minX == 0 && bar.width == C.width && bar.maxY == f.size.height)
        #expect(bar.height >= 2 && bar.height <= 3)
        #expect(bar.minY >= f.buttons[0].maxY)
    }

    @Test func buttonsSitRightAlignedWithTheMinimumWidthAndTheirGap() {
        let one = C.make(input(transcript: 18, labels: [28]))
        #expect(one.buttons.count == 1 && one.buttons[0].width == C.minButtonWidth)
        #expect(one.buttons[0].maxX == C.width - C.insets.side && one.buttons[0].height == C.buttonHeight)
        let two = C.make(input(transcript: 18, labels: [30, 60]))
        #expect(two.buttons[1].maxX == C.width - C.insets.side)
        #expect(two.buttons[0].maxX == two.buttons[1].minX - C.buttonGap)
        #expect(two.buttons[1].width == 60 + 2 * C.buttonPadding && two.buttons[0].width == C.minButtonWidth)
    }

    @Test func everyHitRegionIsInsideTheFaceAndTheyDontOverlap() {
        for transcript in [CGFloat?.none, 18, 200] {
            let f = C.make(input(transcript: transcript, labels: [40, 40], bar: transcript == nil))
            let face = CGRect(origin: .zero, size: f.size)
            let regions = [f.dismiss, f.header] + f.buttons + [f.transcript].compactMap { $0 }
            for region in regions { #expect(face.contains(region)) }
            #expect(f.dismiss.width == 24 && f.dismiss.height == 24 && f.dismiss.maxX == C.width - C.insets.side)
            for (i, a) in regions.enumerated() { for b in regions[(i + 1)...] { #expect(!a.intersects(b)) } }
            #expect(f.buttons.allSatisfy { $0.height >= 26 && $0.width >= 64 })
            #expect(f.dot.midY == C.insets.top + C.rowHeight / 2 && f.dismiss.midY == f.dot.midY)
        }
    }

    @Test func aWrappedHeaderGrowsTheRowAndKeepsTheDotOnTheFirstLine() {
        let one = C.make(input(transcript: 18))
        let two = C.make(input(transcript: 18, header: 32))
        #expect(two.size.height - one.size.height == 12)
        #expect(two.dot.midY == one.dot.midY)
        #expect(two.header.height == 32)
    }

    @Test func theCountdownReadsInWholeSecondsRoundedUp() {
        #expect(C.countdownLabel(remaining: 5) == "5s" && C.countdownLabel(remaining: 4.01) == "5s")
        #expect(C.countdownLabel(remaining: 0.2) == "1s" && C.countdownLabel(remaining: 0) == "0s")
        #expect(C.countdownLabel(remaining: -3) == "0s")
        #expect(C.countdownFraction(remaining: 2.5, total: 5) == 0.5)
        #expect(C.countdownFraction(remaining: 9, total: 5) == 1 && C.countdownFraction(remaining: 1, total: 0) == 0)
    }

    @Test func thePanelSitsCentredJustAboveThePillAndStaysOnScreen() {
        let visible = CGRect(x: 0, y: 40, width: 1440, height: 860)
        let face = CGSize(width: 224, height: 180)
        let frame = C.panelFrame(face: face, pillMidX: 720, pillTop: 60, visible: visible)
        #expect(frame.midX == 720 && frame.width == 224 + 2 * C.shadowMargin)
        // The face's bottom edge is 8 pt above the pill's top.
        #expect(frame.minY + C.shadowMargin == 60 + C.pillGap)
        let edge = C.panelFrame(face: face, pillMidX: 10, pillTop: 60, visible: visible)
        #expect(edge.minX == 0)
        let high = C.panelFrame(face: face, pillMidX: 720, pillTop: 880, visible: visible)
        #expect(high.maxY <= visible.maxY)
    }
}

@MainActor
@Suite struct CardPresenterTests {
    private func rig() -> (DeliveryCardPresenter, FakeSurface, FakeClipboard, FakeClock) {
        let surface = FakeSurface(), clipboard = FakeClipboard(), clock = FakeClock(start: 0)
        return (DeliveryCardPresenter(surface: surface, clipboard: clipboard, clock: clock), surface, clipboard, clock)
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func theListenerHearsEachCardAndWhenItGoes() {
        let (presenter, _, _, _) = rig()
        var changes: [DeliveryCard?] = []
        presenter.onCardChange = { changes.append($0) }
        presenter.present(.secure("hi"))
        presenter.present(.nowhere("hi"))
        presenter.dismiss()
        presenter.dismiss()
        #expect(changes == [.secure("hi"), .nowhere("hi"), nil])
        presenter.present(.cancelled())
        presenter.userDismissed()
        #expect(changes.count == 5 && changes.last! == nil)
    }

    @Test func copyConfirmsInPlaceThenTheCardLeaves() async {
        let (presenter, surface, clipboard, clock) = rig()
        presenter.present(.pasteFailed("hello there"))
        presenter.perform(.copy)
        await settle()

        #expect(clipboard.written == ["hello there"])
        #expect(surface.visible?.copied == true && surface.visible?.card.kind == .pasteFailed)
        clock.advance(by: 0.89)
        await settle()
        #expect(surface.visible != nil)
        clock.advance(by: 0.02)
        await settle()
        #expect(surface.visible == nil && presenter.state == nil)
    }

    @Test func aSecondCopyWhileConfirmingIsIgnored() async {
        let (presenter, _, clipboard, _) = rig()
        presenter.present(.secure("secret words"))
        presenter.perform(.copy)
        presenter.perform(.copy)
        #expect(clipboard.written == ["secret words"])
    }

    @Test func aNewCardReplacesTheOldAndTheOldCopyTimerCannotDismissIt() async {
        let (presenter, surface, _, clock) = rig()
        presenter.present(.nowhere("first"))
        presenter.perform(.copy)
        await settle()
        presenter.present(.pasteFailed("second"))
        clock.advance(by: 5)
        await settle()
        #expect(surface.visible?.card.transcript == "second" && surface.visible?.copied == false)
    }

    @Test func undoHandsOffAndTakesTheCardDown() {
        let (presenter, surface, _, _) = rig()
        var undone = 0
        presenter.onUndo = { undone += 1 }
        presenter.present(.cancelled())
        presenter.perform(.undo)
        #expect(undone == 1 && surface.visible == nil)
        presenter.perform(.undo)
        #expect(undone == 1)
    }

    @Test func actionsTheCardDoesNotOfferAreIgnored() {
        let (presenter, surface, clipboard, _) = rig()
        presenter.present(.cancelled())
        presenter.perform(.copy)
        presenter.perform(.insert)
        #expect(clipboard.written.isEmpty && surface.visible?.card.kind == .cancelled)
    }

    @Test func theDismissControlReportsTheCardAndLeaves() {
        let (presenter, surface, _, _) = rig()
        var dismissed: [DeliveryCard.Kind] = []
        presenter.onDismissed = { dismissed.append($0.kind) }
        presenter.present(.cancelled())
        presenter.userDismissed()
        #expect(dismissed == [.cancelled] && surface.visible == nil)
        presenter.userDismissed()
        #expect(dismissed == [.cancelled])
    }

    @Test func aProgrammaticDismissDoesNotCallBack() {
        let (presenter, surface, _, _) = rig()
        var dismissed = 0
        presenter.onDismissed = { _ in dismissed += 1 }
        presenter.present(.pasteFailed("x"))
        presenter.dismiss()
        #expect(dismissed == 0 && surface.visible == nil)
    }

    @Test func aRecoveredDictationOffersCopyOnly() {
        let (presenter, surface, _, _) = rig()
        presenter.present(.recovered("recovered text"))
        #expect(surface.visible?.card.actions == [.copy])
    }

    @Test func aCardsOwnHandlersRunOnItsButtonsAndGoWithTheCard() {
        let (presenter, surface, _, _) = rig()
        var log: [String] = []
        presenter.present(.micDisconnected(seconds: 4), actions: [.insert: { log.append("insert") }, .discard: { log.append("discard") }])
        presenter.perform(.insert)
        #expect(log == ["insert"] && surface.visible == nil)

        presenter.present(.micDisconnected(seconds: 4), actions: [.insert: { log.append("insert2") }, .discard: { log.append("discard") }])
        presenter.perform(.discard)
        presenter.perform(.insert)
        #expect(log == ["insert", "discard"])

        presenter.present(.recoverOffer(seconds: 12, ago: 120, older: 0), actions: [.recover: { log.append("recover") }])
        presenter.dismiss()
        presenter.perform(.recover)
        #expect(log == ["insert", "discard"])
        presenter.present(.recoverOffer(seconds: 12, ago: 120, older: 0), actions: [.recover: { log.append("recover") }])
        presenter.perform(.recover)
        #expect(log == ["insert", "discard", "recover"])
    }

    @Test func theRecoveryCardsReadAsHeadlineAndDetailLines() {
        let offer = DeliveryCard.recoverOffer(seconds: 12, ago: 125, older: 0)
        #expect(offer.header == "Recover your last dictation?\n12 seconds, 2 minutes ago")
        #expect(offer.actions == [.recover, .discard] && offer.countdown == nil && offer.kind.isQuiet)
        #expect(DeliveryCard.recoverOffer(seconds: 61, ago: 30, older: 2).header
                == "Recover your last dictation?\n1 minute 1 second, just now\nand 2 older ones in Saved Recordings")
        #expect(DeliveryCard.recoverOffer(seconds: 1, ago: 7200, older: 1).header.hasSuffix("1 second, 2 hours ago\nand 1 older one in Saved Recordings"))
        let mic = DeliveryCard.micDisconnected(seconds: 7.4)
        #expect(mic.header == "Microphone disconnected\n7 seconds recorded" && mic.actions == [.insert, .discard] && !mic.kind.isQuiet)
        let limit = DeliveryCard.limitWarning(stopsAfter: 20 * 60)
        #expect(limit.header == "One minute left\nRecording stops at 20 minutes" && limit.actions.isEmpty)
    }

    @Test func eachCardCaseHasItsHeaderAndActions() {
        #expect(DeliveryCard.secure("t").header == "Secure field, not pasted")
        #expect(DeliveryCard.nowhere("t").header == "Nothing to paste into")
        #expect(DeliveryCard.pasteFailed("t").header == "Paste failed")
        #expect(DeliveryCard.cancelled().header == "Cancelled" && DeliveryCard.cancelled().countdown == 5)
        #expect(DeliveryCard.cancelled().actions == [.undo] && DeliveryCard.cancelled().transcript == nil)
        for card in [DeliveryCard.secure("t"), .nowhere("t"), .pasteFailed("t")] {
            #expect(card.actions == [.copy] && card.countdown == nil && card.transcript == "t")
        }
    }
}

@MainActor
@Suite struct CardViewTests {
    init() { FontRegistry.registerBundledFonts() }

    private let words = (0..<70).map { "word\($0)" }.joined(separator: " ")

    @Test func aLongTranscriptScrollsInsideAndAShortOneGrows() {
        _ = NSApplication.shared
        let view = DeliveryCardView(frame: .zero)
        view.render(CardViewState(card: .pasteFailed("Move the standup to three thirty.")), typography: Typography(choice: .systema))
        let short = view.frames
        #expect(short?.transcriptScrolls == false)
        view.render(CardViewState(card: .pasteFailed(words)), typography: Typography(choice: .systema))
        let long = view.frames
        #expect(long?.transcriptScrolls == true)
        #expect((long?.size.height ?? 0) > (short?.size.height ?? 0))
        #expect((long?.size.height ?? 0) < 260)
    }

    @Test func theCardMeasuresWithWhicheverFontIsChosen() {
        _ = NSApplication.shared
        var heights: [CGFloat] = []
        for choice in [TextFontChoice.systema, .system, .mono, .serif] {
            let view = DeliveryCardView(frame: .zero)
            let size = view.render(CardViewState(card: .pasteFailed(words)), typography: Typography(choice: choice))
            heights.append(size.height)
            #expect(size.width == C.width + 2 * C.shadowMargin)
            #expect(view.frames?.transcriptScrolls == true)
        }
        #expect(Set(heights).count >= 1)
    }

    private typealias C = CardLayout

    @Test func theCardPanelNeverTakesFocus() {
        _ = NSApplication.shared
        let controller = DeliveryCardController()
        #expect(!controller.panel.canBecomeKey && !controller.panel.canBecomeMain)
        #expect(controller.panel.styleMask.contains(.nonactivatingPanel))
        #expect(!controller.panel.ignoresMouseEvents)
    }

    @Test func rendersPlaceTheControlsInsideThePanel() {
        _ = NSApplication.shared
        let controller = DeliveryCardController()
        controller.anchor = { .init(midX: 500, top: 100, visible: CGRect(x: 0, y: 0, width: 1000, height: 800)) }
        controller.render(CardViewState(card: .pasteFailed("hello")))
        let frame = controller.panel.frame
        let copy = controller.screenCenter(of: .copy)
        #expect(copy != nil && frame.contains(copy ?? .zero) && frame.contains(controller.dismissScreenCenter))
        #expect(frame.midX == 500 && frame.minY + C.shadowMargin == 100 + C.pillGap)
        #expect(controller.screenCenter(of: .undo) == nil)
        controller.render(nil)
    }

    @Test func aButtonFiresOnMouseUpInsideAndNotAfterDraggingOut() throws {
        _ = NSApplication.shared
        let panel = CardPanel(contentRect: NSRect(x: 0, y: 0, width: 100, height: 60), styleMask: [.borderless], backing: .buffered, defer: false)
        let button = CardButtonView(frame: NSRect(x: 10, y: 10, width: 64, height: 26))
        panel.contentView?.addSubview(button)
        var fired = 0
        button.onClick = { fired += 1 }
        func event(_ type: NSEvent.EventType, at point: CGPoint) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(
                with: type, location: point, modifierFlags: [], timestamp: 0, windowNumber: panel.windowNumber,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            ))
        }
        let inside = button.convert(CGPoint(x: 32, y: 13), to: nil)
        #expect(button.acceptsFirstMouse(for: nil) && !button.mouseDownCanMoveWindow)
        button.mouseDown(with: try event(.leftMouseDown, at: inside))
        #expect(button.isPressed)
        button.mouseUp(with: try event(.leftMouseUp, at: inside))
        #expect(fired == 1 && !button.isPressed)

        button.mouseDown(with: try event(.leftMouseDown, at: inside))
        button.mouseDragged(with: try event(.leftMouseDragged, at: CGPoint(x: 400, y: 400)))
        #expect(!button.isPressed)
        button.mouseUp(with: try event(.leftMouseUp, at: CGPoint(x: 400, y: 400)))
        #expect(fired == 1)
    }
}
