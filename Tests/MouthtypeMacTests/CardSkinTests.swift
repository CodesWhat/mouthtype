import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
private final class StubClipboard: ClipboardWriting {
    var written: [String] = []
    func write(_ text: String) { written.append(text) }
}

/// A real pill, card window and presenter wired the way the app wires them, on one skin and size.
@MainActor
private final class CardRig {
    let pill: PillController
    let cards = DeliveryCardController()
    let presenter: DeliveryCardPresenter
    let clock = FakeClock(start: 0)
    let defaults: UserDefaults

    init(skin: String, size: String = "standard") {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        defaults = UserDefaults(suiteName: "card-skin-test-\(UUID().uuidString)")!
        defaults.set(skin, forKey: "pillSkin")
        defaults.set(size, forKey: "pillSize")
        pill = PillController(level: { .silence }, defaults: defaults)
        pill.cardSettle = 0
        presenter = DeliveryCardPresenter(surface: cards, clipboard: StubClipboard(), clock: clock)
        cards.anchor = { [weak pill] in pill?.cardAnchor() }
        cards.onAction = { [weak presenter] in presenter?.perform($0) }
        cards.onDismiss = { [weak presenter] in presenter?.userDismissed() }
        presenter.onCardChange = { [weak pill] card in
            if let message = card?.pillMessage { pill?.showCardMessage(message) } else { pill?.hideCardMessage() }
        }
    }

    var squircle: SquirclePillView? { pill.skin as? SquirclePillView }

    /// A point in the panel's host view, as a screen point.
    func screen(_ point: CGPoint) -> CGPoint {
        pill.panel.convertPoint(toScreen: pill.host.convert(point, to: nil))
    }

    func finish() {
        presenter.dismiss()
        pill.hide()
    }
}

@MainActor
@Suite struct CardScaleTests {
    typealias C = CardLayout

    private func input(scale k: CGFloat) -> C.Input {
        C.Input(
            headerTextHeight: 16 * k, headerLineHeight: 16 * k, transcriptTextHeight: 54 * k, transcriptLineHeight: 18 * k,
            buttonLabelWidths: [28 * k, 40 * k], hasCountdownBar: true
        )
    }

    @Test func largeIsExactlyTwiceStandardInEveryLength() throws {
        let one = C.make(input(scale: 1)), two = C.make(input(scale: 2), scale: 2)
        #expect(two.size == CGSize(width: one.size.width * 2, height: one.size.height * 2))
        #expect(two.size.width == 448)
        func doubled(_ r: CGRect?) -> CGRect? { r.map { CGRect(x: $0.minX * 2, y: $0.minY * 2, width: $0.width * 2, height: $0.height * 2) } }
        #expect(two.dot == doubled(one.dot) && two.header == doubled(one.header) && two.dismiss == doubled(one.dismiss))
        #expect(two.transcript == doubled(one.transcript) && two.bar == doubled(one.bar))
        #expect(two.buttons == one.buttons.map { doubled($0)! })
        let bar = try #require(two.bar)
        #expect(two.dismiss.width == 48 && two.buttons[0].height == 52 && bar.height == 6)
    }

    @Test func theFiveLineCapDoublesToo() {
        var long = input(scale: 2)
        long.transcriptTextHeight = 800
        let frames = C.make(long, scale: 2)
        #expect(frames.transcriptScrolls && frames.transcript?.height == 5 * 36)
    }

    @Test func aCardWithoutADotGivesTheTextTheDotsRoom() {
        let withDot = C.make(input(scale: 1)), without = C.make(input(scale: 1), showsDot: false)
        #expect(withDot.header.minX == 25 && without.header.minX == 12)
        #expect(without.header.width - withDot.header.width == 13)
        #expect(without.size == withDot.size)
    }

    @Test func thePanelFrameScalesTheMarginAndTheGap() {
        let visible = CGRect(x: 0, y: 0, width: 2000, height: 1200)
        let standard = C.panelFrame(face: CGSize(width: 224, height: 100), pillMidX: 1000, pillTop: 60, visible: visible)
        let large = C.panelFrame(face: CGSize(width: 448, height: 200), pillMidX: 1000, pillTop: 60, visible: visible, scale: 2)
        #expect(standard.width == 256 && large.width == 512)
        #expect(standard.minY == 60 + 8 - 16 && large.minY == 60 + 16 - 32)
    }

    @Test(arguments: [CardStyle.classic, .glass, .matrix, .minimal], [PillScale.standard, .large])
    func everySkinsCardLaysOutAtTheScale(style: CardStyle, scale: PillScale) throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let k = scale.factor
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: style, scale: scale, embedded: style.mergesIntoPill)
        let size = view.render(CardViewState(card: .rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean"))), typography: Typography(choice: .systema))
        let frames = try #require(view.frames)
        let margin = style.mergesIntoPill ? 0 : C.shadowMargin * k
        #expect(frames.size.width == 224 * k && size.width == 224 * k + 2 * margin)
        #expect(frames.dismiss.width == 24 * k && frames.dismiss.height == 24 * k)
        #expect(frames.buttons.count == 2 && frames.buttons.allSatisfy { $0.height == 26 * k && $0.width >= 64 * k })
        #expect(frames.bar?.height == (style.mergesIntoPill ? nil : 3 * k))
        #expect(frames.header.minX == (style.mergesIntoPill ? 12 : 25) * k)
        #expect(view.showsDot == !style.mergesIntoPill)
        #expect(frames.buttons.last?.maxX == 212 * k)
        #expect(view.palette.showsDot == !style.mergesIntoPill)
    }

    @Test(arguments: [CardStyle.classic, .glass, .matrix, .minimal], [PillScale.standard, .large])
    func aLongTranscriptStopsAtFiveLinesAtEitherSize(style: CardStyle, scale: PillScale) throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: style, scale: scale, embedded: style.mergesIntoPill)
        let words = Array(repeating: "the quarterly numbers are due Friday", count: 30).joined(separator: " ")
        view.render(CardViewState(card: .pasteFailed(words)), typography: Typography(choice: .systema))
        let frames = try #require(view.frames)
        #expect(frames.transcriptScrolls)
        let line = Typography(choice: .systema).font(.body, scale: scale.factor)
        let lineHeight = Typography.lineHeight(line) + max(0, round(line.pointSize * 1.38) - Typography.lineHeight(line))
        #expect(frames.transcript?.height == ceil(5 * lineHeight))
    }
}

@MainActor
@Suite struct CardPaletteTests {
    private func hex(_ value: UInt32) -> NSColor { NSColor(hex: value) }

    @Test func hiFiWearsTheClassicCard() {
        #expect(PillSkinKind.hifi.cardStyle == .classic && PillSkinKind.classic.cardStyle == .classic)
        #expect(PillSkinKind.glass.cardStyle == .glass && PillSkinKind.matrix.cardStyle == .matrix && PillSkinKind.minimal.cardStyle == .minimal)
        let hifi = CardPalette.resolve(style: PillSkinKind.hifi.cardStyle, dark: false)
        #expect(hifi.ink == hex(0xF4F3E8) && hifi.primaryFill == hex(0xF4F3E8) && hifi.bodyFill != nil && hifi.showsDot)
        #expect(hifi.accent(for: .pasteFailed) == hex(0xFF453A) && hifi.accent(for: .rememberSpelling) == hex(0xF4F3E8))
    }

    @Test func glassQuestionsGetTheAmberAccentAndSecondaryButtonsAreChips() {
        let glass = CardPalette.resolve(style: .glass, dark: true, glass: .glass(.smoked))
        #expect(glass.accent(for: .rememberSpelling) == hex(0xFFB327) && glass.accent(for: .forgetSpelling) == hex(0xFFB327))
        #expect(glass.accent(for: .recoverOffer) == hex(0xFFB327))
        #expect(glass.accent(for: .pasteFailed) == hex(0xFF453A) && glass.accent(for: .recovered) == hex(0xF4F3E8))
        #expect(glass.chips && glass.bodyFill == nil && glass.showsDot)
        #expect(!CardPalette.classic.chips)
    }

    @Test func clearGlassUsesTheDarkInk() {
        let clear = CardPalette.resolve(style: .glass, dark: false, glass: .glass(.clear))
        #expect(clear.ink == hex(0x1D1D1F) && clear.warn == hex(0xD70015) && clear.primaryFill == hex(0x1D1D1F))
        let solid = CardPalette.resolve(style: .glass, dark: false, glass: .solid(.lowContrast))
        #expect(solid.ink == hex(0xF4F3E8) && solid.bodyFill != nil)
    }

    @Test func matrixIsAnAmberSquircleOnTheMatrixBody() {
        for dark in [true, false] {
            let matrix = CardPalette.resolve(style: .matrix, dark: dark)
            #expect(matrix.primaryFill == hex(0xFFB327) && matrix.squircleControls && !matrix.showsDot && matrix.bodyFill == nil)
        }
        #expect(CardPalette.resolve(style: .matrix, dark: true).ink == hex(0xF4F3E8))
    }

    @Test func minimalLightAndDarkFollowTheSpec() {
        let light = CardPalette.resolve(style: .minimal, dark: false)
        #expect(light.ink == hex(0x1D1D1F) && light.warn == hex(0xD70015) && light.quiet == hex(0x315B54))
        #expect(light.accent(for: .recovered) == hex(0x315B54) && light.accent(for: .pasteFailed) == hex(0xD70015))
        #expect(light.primaryFill == hex(0x1D1D1F))
        let dark = CardPalette.resolve(style: .minimal, dark: true)
        #expect(dark.ink == hex(0xF4F3E8) && dark.primaryFill == hex(0xF4F3E8))
        #expect(SquirclePalette.lightBody.top == hex(0xFBFBFC))
    }
}

@MainActor
@Suite struct GlassCardTests {
    private func env(available: Bool = true, reduce: Bool = false, backdrop: GlassPillPolicy.Backdrop? = .init(luminance: 0.1, spread: 0.02)) -> GlassPillEnvironment {
        GlassPillEnvironment(materialAvailable: { available }, reduceTransparency: { reduce }, backdrop: { _ in backdrop })
    }

    private func card(_ environment: GlassPillEnvironment) -> DeliveryCardView {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let view = DeliveryCardView(frame: .zero, environment: environment)
        view.configure(style: .glass, scale: .standard, embedded: false)
        view.render(CardViewState(card: .pasteFailed("Send the notes.")), typography: Typography(choice: .systema))
        view.refreshBackdrop()
        return view
    }

    @Test func darkBackdropsGetSmokedGlassAndLightOnesClear() {
        #expect(card(env()).glassDecision == .glass(.smoked) && card(env()).showsMaterial)
        let light = card(env(backdrop: .init(luminance: 0.9, spread: 0.02)))
        #expect(light.glassDecision == .glass(.clear) && light.showsMaterial)
        #expect(light.palette.ink == NSColor(hex: 0x1D1D1F))
    }

    @Test func theSameSolidFallbacksAsThePill() {
        #expect(card(env(available: false)).glassDecision == .solid(.materialUnavailable))
        #expect(card(env(reduce: true)).glassDecision == .solid(.reduceTransparency))
        #expect(card(env(backdrop: .init(luminance: 0.5, spread: 0.02))).glassDecision == .solid(.lowContrast))
        #expect(card(env(backdrop: .init(luminance: 0.1, spread: 0.5))).glassDecision == .solid(.lowContrast))
        let solid = card(env(available: false))
        #expect(!solid.showsMaterial && solid.palette.bodyFill != nil && solid.palette.ink == NSColor(hex: 0xF4F3E8))
    }

    @Test func otherSkinsNeverUseTheMaterial() {
        _ = NSApplication.shared
        let view = DeliveryCardView(frame: .zero, environment: env())
        view.configure(style: .classic, scale: .standard, embedded: false)
        view.render(CardViewState(card: .pasteFailed("x")), typography: Typography(choice: .systema))
        view.refreshBackdrop()
        #expect(!view.showsMaterial)
    }
}

@MainActor
@Suite struct CardReadoutTests {
    private func readout(_ card: DeliveryCard) -> CardReadout? {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let view = DeliveryCardView(frame: .zero)
        view.configure(style: .matrix, scale: .standard, embedded: true)
        view.render(CardViewState(card: card), typography: Typography(choice: .systema))
        return view.readout
    }

    @Test func aTranscriptCardSaysSafe() {
        let failed = readout(.pasteFailed("x"))
        #expect(failed == CardReadout(label: "SAFE", isClock: false, tone: .alert, progress: nil))
        #expect(readout(.recovered("x"))?.tone == .quiet)
    }

    @Test func aCountdownCardShowsTheClockAndTheBar() throws {
        let undo = try #require(readout(.cancelled()))
        #expect(undo.isClock && undo.label == "0:05" && undo.tone == .alert && (undo.progress ?? 0) > 0.9)
        let ask = try #require(readout(.rememberSpelling(SpellingPair(heard: "a", corrected: "b"))))
        #expect(ask.isClock && ask.label == "0:08" && ask.tone == .question)
    }

    @Test func aCardWithNothingToReassureAboutHasAnEmptyLabel() {
        #expect(readout(.micDisconnected(seconds: 4))?.label == "")
    }
}

@MainActor
@Suite struct CardGrowTests {
    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func eachSkinPicksItsCardStyleAndSizeFromTheAnchor() throws {
        for kind in PillSkinKind.allCases {
            for (size, scale) in [("standard", PillScale.standard), ("large", .large)] {
                let rig = CardRig(skin: kind.rawValue, size: size)
                let anchor = try #require(rig.pill.cardAnchor())
                #expect(anchor.style == kind.cardStyle && anchor.scale == scale && anchor.merger != nil)
            }
        }
    }

    @Test(arguments: ["classic", "glass", "hifi"])
    func theOtherSkinsKeepTheirOwnCardPanel(skin: String) {
        let rig = CardRig(skin: skin)
        rig.presenter.present(.pasteFailed("Send the notes."))
        #expect(!rig.cards.isMerged && !rig.pill.isGrown)
        #expect(rig.cards.panel.isVisible)
        #expect(rig.cards.view.style == (skin == "glass" ? .glass : .classic))
        #expect(rig.cards.view.palette.showsDot)
        if skin == "hifi" { #expect(rig.cards.view.palette.primaryFill == NSColor(hex: 0xF4F3E8)) }
        rig.finish()
    }

    @Test func largeCardsAreTwiceAsWideForEverySkinWithAPanel() {
        for skin in ["classic", "glass", "hifi"] {
            let rig = CardRig(skin: skin, size: "large")
            rig.presenter.present(.pasteFailed("Send the notes."))
            #expect(rig.cards.panel.frame.width == 512)
            #expect(rig.cards.view.faceSize.width == 448)
            rig.finish()
        }
    }

    @Test(arguments: ["matrix", "minimal"], ["standard", "large"])
    func thePillGrowsUpwardIntoTheCardWithNoPanelOfItsOwn(skin: String, size: String) throws {
        let rig = CardRig(skin: skin, size: size)
        let k: CGFloat = size == "large" ? 2 : 1
        rig.presenter.present(.pasteFailed("Send the notes to Priya."))
        #expect(rig.cards.isMerged && rig.pill.isGrown)
        #expect(!rig.cards.panel.isVisible)
        let squircle = try #require(rig.squircle)
        let grown = try #require(squircle.grownFrame)
        let face = rig.cards.mergedView.faceSize
        #expect(grown.width == 224 * k && face.width == 224 * k)
        #expect(grown.height == face.height + 30 * k)
        let panel = rig.pill.panel.frame
        #expect(panel.height >= grown.height + 20 + 16 * k && panel.width >= grown.width + 32 * k)
        #expect(panel.height > PillGeometry.panelSize(for: k == 2 ? .large : .standard).height || panel.width > grown.width)
        #expect(abs(panel.midX - (rig.screen(CGPoint(x: grown.midX, y: grown.midY)).x)) <= 1)
        #expect(squircle.cardFrame?.maxY == grown.maxY && squircle.cardFrame?.height == face.height)
        #expect(rig.pill.cardView === rig.cards.mergedView && rig.pill.host.cardView === rig.cards.mergedView)
        // The row stays at the bottom and says the short thing, and the long line under the card is gone.
        #expect(squircle.readoutLabel == "SAFE" && squircle.lampTone == .alert && rig.pill.cardHeld)
        #expect(squircle.rowRect.height == 30 * k && squircle.rowRect.minY == grown.minY)
        rig.finish()
    }

    @Test func theCardKeepsItsButtonsAndTheirClicks() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.pasteFailed("Send the notes."))
        let copy = try #require(rig.cards.mergedView.buttonFrames[.copy])
        let center = rig.pill.host.convert(CGPoint(x: copy.midX, y: copy.midY), from: rig.cards.mergedView)
        // The pill's host hands the click to the card's button rather than swallowing it.
        let hit = rig.pill.host.hitTest(rig.pill.host.convert(center, to: rig.pill.host.superview))
        #expect(hit is CardButtonView)
        (hit as? CardButtonView)?.onClick?()
        #expect(rig.presenter.state?.copied == true)
        rig.finish()
    }

    @Test func thePanelTakesClicksOnlyOverTheGrownCard() throws {
        let rig = CardRig(skin: "matrix")
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.presenter.present(.pasteFailed("Send the notes."))
        let grown = try #require(rig.squircle?.grownFrame)
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: grown.midX, y: grown.midY)))
        #expect(!rig.pill.panel.ignoresMouseEvents)
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: grown.maxX + 6, y: grown.midY)))
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: grown.midX, y: grown.maxY + 6)))
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: grown.minX + 2, y: grown.minY + 2)))
        #expect(!rig.pill.panel.ignoresMouseEvents)
        rig.presenter.dismiss()
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: grown.midX, y: grown.midY)))
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.finish()
    }

    @Test func dismissShrinksTheCardBackToAPillAndTheMessageGoes() async throws {
        let rig = CardRig(skin: "minimal")
        let standard = rig.pill.panelSize
        rig.presenter.present(.pasteFailed("Send the notes."))
        #expect(rig.pill.panel.frame.height > standard.height)
        rig.presenter.userDismissed()
        #expect(!rig.pill.isGrown && !rig.cards.isMerged && rig.pill.cardView == nil && rig.pill.host.cardView == nil)
        #expect(rig.squircle?.grownFrame == nil && rig.pill.state == .hidden && rig.pill.panel.ignoresMouseEvents)
        // A pill that was only there for the card comes back the right size next time.
        rig.pill.showRecording()
        #expect(rig.pill.panel.frame.size == standard && rig.pill.state == .recording)
        rig.finish()
    }

    @Test func aPillBusyWithSomethingElseKeepsItsPanelUntilTheMotionIsDone() async throws {
        let rig = CardRig(skin: "matrix")
        let standard = rig.pill.panelSize
        rig.pill.showRecording()
        rig.presenter.present(.cancelled())
        #expect(rig.pill.state == .recording && rig.pill.isGrown)
        #expect(rig.pill.panel.frame.height > standard.height)
        rig.presenter.dismiss()
        for _ in 0..<100 where rig.pill.panel.frame.size != standard { try await Task.sleep(for: .milliseconds(10)) }
        #expect(rig.pill.state == .recording && rig.pill.panel.frame.size == standard)
        rig.finish()
    }

    @Test func aReplacedCardStaysGrownAndResizes() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.pasteFailed("Send the notes."))
        let first = try #require(rig.squircle?.grownFrame)
        rig.presenter.present(.pasteFailed(Array(repeating: "the quarterly numbers are due Friday", count: 12).joined(separator: " ")))
        let second = try #require(rig.squircle?.grownFrame)
        #expect(rig.pill.isGrown && rig.cards.isMerged && second.height > first.height && second.minY == first.minY)
        rig.presenter.present(.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")))
        #expect(rig.pill.isGrown && rig.squircle?.readoutLabel == "0:08" && rig.squircle?.lampTone == .question)
        #expect(!rig.pill.cardHeld)
        rig.presenter.present(.pasteFailed("again"))
        #expect(rig.squircle?.readoutLabel == "SAFE" && rig.pill.cardHeld)
        rig.presenter.dismiss()
        #expect(!rig.pill.isGrown)
        rig.finish()
    }

    @Test func aCardWithoutALineHoldsTheGrownPillByItself() throws {
        let rig = CardRig(skin: "minimal")
        rig.presenter.present(.cancelled())
        #expect(rig.pill.isGrown && rig.pill.state == .hidden && !rig.pill.cardHeld)
        #expect(rig.squircle?.readoutLabel == "0:05" && rig.squircle?.cardProgress != nil)
        #expect(rig.pill.panel.isVisible)
        rig.presenter.dismiss()
        #expect(!rig.pill.isGrown && rig.pill.state == .hidden)
        rig.finish()
    }

    @Test func aTimeoutShrinksTheCard() async throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.rememberSpelling(SpellingPair(heard: "Shawn", corrected: "Sean")))
        await settle()
        #expect(rig.pill.isGrown)
        rig.clock.advance(by: DeliveryCard.offerWindow + 0.1)
        await settle()
        #expect(rig.presenter.state == nil && !rig.pill.isGrown && !rig.cards.isMerged)
        #expect(rig.pill.panel.ignoresMouseEvents)
        rig.finish()
    }

    @Test func aNewRecordingWhileGrownKeepsTheCardAndTakesTheRow() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.micDisconnected(seconds: 3))
        #expect(rig.pill.isGrown)
        rig.pill.showRecording()
        #expect(rig.pill.state == .recording && rig.pill.isGrown && rig.cards.isMerged)
        #expect(rig.squircle?.lampTone == nil && rig.squircle?.grownFrame != nil)
        rig.pill.hide()
        #expect(rig.pill.state == .hidden && rig.pill.isGrown && rig.pill.panel.isVisible)
        rig.presenter.dismiss()
        #expect(!rig.pill.isGrown)
        rig.finish()
    }

    @Test func aNewRecordingAfterTheCardWentStartsFromAPlainPill() throws {
        let rig = CardRig(skin: "minimal")
        let standard = rig.pill.panelSize
        rig.presenter.present(.pasteFailed("Send the notes."))
        rig.presenter.dismiss()
        rig.pill.showRecording()
        #expect(!rig.pill.isGrown && rig.pill.state == .recording && rig.squircle?.grownFrame == nil)
        #expect(rig.pill.panel.frame.size == standard && rig.pill.panel.ignoresMouseEvents)
        rig.finish()
    }

    @Test func handsFreeControlsStillWorkUnderAGrownCard() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.micDisconnected(seconds: 3))
        rig.pill.showHandsFree()
        let stop = try #require(rig.pill.skin.controlFrames[.stop])
        let row = try #require(rig.squircle?.rowRect)
        #expect(row.contains(CGPoint(x: stop.midX, y: stop.midY)))
        rig.pill.updateInteractivity(pointer: rig.screen(CGPoint(x: stop.midX, y: stop.midY)))
        #expect(!rig.pill.panel.ignoresMouseEvents)
        rig.finish()
    }

    @Test func swappingToAClassicSkinTakesTheCardBackOutOfThePill() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.pasteFailed("x"))
        #expect(rig.cards.isMerged)
        rig.cards.anchor = { .init(midX: 500, top: 100, visible: CGRect(x: 0, y: 0, width: 1000, height: 800)) }
        rig.presenter.present(.pasteFailed("y"))
        #expect(!rig.cards.isMerged && !rig.pill.isGrown && rig.cards.panel.isVisible)
        rig.finish()
    }
}

/// A merger whose pill never takes a card, standing in for a skin that was swapped under the card.
@MainActor
private final class RefusingMerger: CardMerging {
    func growCard(view: DeliveryCardView, face: CGSize, readout: CardReadout) -> Bool { false }
    func updateCardReadout(_ readout: CardReadout) {}
    func shrinkCard() {}
}

@MainActor
@Suite struct CardReviewFixTests {
    private let longText = Array(repeating: "the quarterly numbers are due Friday", count: 30).joined(separator: " ")

    // MARK: Centred readout

    @Test(arguments: ["matrix", "minimal"], ["standard", "large"])
    func theReadoutGroupSitsInTheMiddleOfTheGrownRow(skin: String, size: String) throws {
        let k: CGFloat = size == "large" ? 2 : 1
        for card in [DeliveryCard.pasteFailed("Send the notes."), .cancelled()] {
            let rig = CardRig(skin: skin, size: size)
            rig.presenter.present(card)
            let squircle = try #require(rig.squircle)
            let grown = try #require(squircle.grownFrame)
            let group = try #require(squircle.readoutGroupExtent)
            // The same room on each side, to the pixel the capsule snaps to.
            #expect(abs(group.minX - (grown.width - group.maxX)) <= 1.5 * k)
            #expect(group.minX > 12 * k)
            // The label really moved with it.
            #expect(abs(squircle.readoutLabelMinX - (group.minX + 62 * k)) <= 0.5)
            rig.finish()
        }
    }

    @Test func aRecordingUnderTheCardKeepsThePillsOwnSlots() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.pasteFailed("x"))
        rig.pill.showRecording()
        #expect(rig.squircle?.readoutGroupExtent == nil)
        rig.finish()
    }

    // MARK: F1

    @Test func aSkinSwitchedMidDictationGivesTheNextCardItsBodyBack() throws {
        let rig = CardRig(skin: "matrix")
        rig.pill.showRecording()
        rig.pill.setSkin(.classic)
        #expect(rig.pill.skinKind == .matrix)
        rig.pill.hide()
        rig.presenter.present(.pasteFailed("Send the notes."))
        #expect(rig.pill.skinKind == .classic && !rig.cards.isMerged && !rig.pill.isGrown)
        #expect(rig.cards.panel.isVisible && rig.cards.view.style == .classic)
        #expect(rig.cards.view.palette.bodyFill != nil && rig.cards.view.palette.border != nil)
        rig.finish()
    }

    @Test func aPillThatRefusesTheCardFallsBackToAPaletteWithABody() throws {
        let rig = CardRig(skin: "matrix")
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let merger = RefusingMerger()
        rig.cards.anchor = { .init(midX: 500, top: 100, visible: visible, style: .matrix, scale: .standard, merger: merger) }
        rig.presenter.present(.pasteFailed("x"))
        #expect(!rig.cards.isMerged && rig.cards.panel.isVisible)
        #expect(rig.cards.view.style == .classic && rig.cards.view.palette.bodyFill != nil)
        rig.finish()
    }

    // MARK: F2

    @Test func aGrownHiddenPillKeepsItsScaleWhateverTheSettingResolvesTo() throws {
        let rig = CardRig(skin: "matrix", size: "standard")
        rig.presenter.present(.cancelled())
        #expect(rig.pill.isGrown && rig.pill.state == .hidden)
        rig.defaults.set("large", forKey: "pillSize")
        let anchor = try #require(rig.pill.cardAnchor())
        #expect(anchor.scale == .standard && rig.cards.mergedView.pillScale == .standard)
        rig.presenter.dismiss()
        // Once it is down the new setting is picked up, for the card and the pill together.
        #expect(rig.pill.cardAnchor()?.scale == .large)
        rig.finish()
    }

    // MARK: F3

    @Test func theCardContentFadesInOnTheBodysOwnTiming() {
        #expect(PillController.cardFadeDuration(appearing: true, reduceMotion: false) == 0.26)
        #expect(PillController.cardFadeDuration(appearing: true, reduceMotion: true) == 0.15)
        #expect(PillController.cardFadeDuration(appearing: true, reduceMotion: false) == SquirclePillView.appearDuration(reduceMotion: false))
        #expect(PillController.cardFadeDuration(appearing: false, reduceMotion: false) == 0.12)
    }

    @Test func aCardRightAfterHideTurnsTheFadeRoundInsteadOfSnappingToNothing() throws {
        let rig = CardRig(skin: "matrix")
        rig.pill.showRecording()
        rig.pill.hide()
        #expect(rig.pill.state == .hidden && rig.pill.panel.isVisible)
        rig.presenter.present(.pasteFailed("Send the notes."))
        let squircle = try #require(rig.squircle)
        #expect(squircle.appearStartOpacity > 0.5)
        #expect(rig.pill.isGrown && rig.pill.panel.isVisible)
        rig.finish()
    }

    @Test func aCardOnAPillThatWasFullyDownStartsFromNothing() throws {
        let rig = CardRig(skin: "minimal")
        rig.presenter.present(.pasteFailed("Send the notes."))
        #expect(rig.squircle?.appearStartOpacity == 0)
        rig.finish()
    }

    @Test func theFadeOutCurveRunsFromTheStartingOpacityDownToNothing() {
        #expect(SquirclePillView.fadeOutOpacity(from: 1, elapsed: 0, duration: 0.16) == 1)
        let middle = SquirclePillView.fadeOutOpacity(from: 1, elapsed: 0.08, duration: 0.16)
        #expect(middle > 0.5 && middle < 1)
        #expect(SquirclePillView.fadeOutOpacity(from: 1, elapsed: 0.16, duration: 0.16) < 0.001)
        #expect(SquirclePillView.fadeOutOpacity(from: 0.5, elapsed: 0, duration: 0.16) == 0.5)
    }

    // MARK: F4

    @Test func theGlassCardKeepsADropShadowWithItsClearBackground() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let env = GlassPillEnvironment(
            materialAvailable: { true }, reduceTransparency: { false }, backdrop: { _ in .init(luminance: 0.1, spread: 0.02) }
        )
        let view = DeliveryCardView(frame: .zero, environment: env)
        view.configure(style: .glass, scale: .standard, embedded: false)
        view.render(CardViewState(card: .pasteFailed("Send the notes.")), typography: Typography(choice: .systema))
        view.refreshBackdrop()
        #expect(view.showsMaterial)
        for path in view.shadowPaths {
            let bounds = try #require(path).boundingBoxOfPath
            #expect(bounds.size == view.faceSize)
        }
    }

    // MARK: F5

    @Test func aLightMinimalCardHasItsOwnLighterBodyAndThePillKeepsItsOwn() {
        _ = NSApplication.shared
        let card = MinimalPillView(frame: NSRect(x: 0, y: 0, width: 300, height: 300))
        card.appearance = NSAppearance(named: .aqua)
        #expect(card.bodyColours == [NSColor(hex: 0xFBFBFC), NSColor(hex: 0xE6E6EA)])
        card.growCard(width: 224, height: 120, readout: CardReadout(label: "SAFE", isClock: false, tone: .alert, progress: nil), showReadout: true)
        #expect(card.bodyColours == [NSColor(hex: 0xFBFBFC), NSColor(hex: 0xF0F0F3)])
        card.shrinkCard()
        #expect(card.bodyColours == [NSColor(hex: 0xFBFBFC), NSColor(hex: 0xE6E6EA)])
        card.appearance = NSAppearance(named: .darkAqua)
        card.growCard(width: 224, height: 120, readout: CardReadout(label: "SAFE", isClock: false, tone: .alert, progress: nil), showReadout: true)
        #expect(card.bodyColours == [SquirclePalette.darkBody.top, SquirclePalette.darkBody.bottom])
    }

    // MARK: F6

    @Test func aGrownPanelStaysOnAShortScreenAndTheTranscriptScrollsToFit() throws {
        let rig = CardRig(skin: "matrix")
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 200)
        rig.pill.screensSource = { [.init(frame: CGRect(x: 0, y: 0, width: 1000, height: 220), visibleFrame: visible)] }
        rig.pill.pointerSource = { CGPoint(x: 500, y: 100) }
        rig.presenter.present(.pasteFailed(longText))
        let squircle = try #require(rig.squircle)
        let anchor = try #require(rig.pill.cardAnchor())
        let maxFace = try #require(anchor.maxFaceHeight)
        let face = rig.cards.mergedView.faceSize
        #expect(face.height <= maxFace && rig.cards.mergedView.frames?.transcriptScrolls == true)
        let panel = rig.pill.panel.frame
        #expect(panel.maxY <= visible.maxY && panel.minX >= visible.minX && panel.maxX <= visible.maxX)
        let grown = try #require(squircle.grownFrame)
        #expect(grown.maxY <= rig.pill.host.bounds.maxY && grown.minY >= 0)
        rig.finish()
    }

    @Test func theGrownFrameKeepsItsBottomAndMiddleAndNeverClipsTheCapsule() {
        let visible = CGRect(x: 0, y: 0, width: 1000, height: 300)
        let old = CGRect(x: 100, y: -8, width: 256, height: 100)
        let plain = CGSize(width: 256, height: 100)
        let roomy = PillController.grownFrame(old: old, face: CGSize(width: 224, height: 100), plainSize: plain, scale: 1, visible: visible)
        #expect(roomy.minY == old.minY && roomy.midX == old.midX && roomy.maxY <= visible.maxY)
        // Too tall for the room above the pill: the panel stops at the screen top.
        let tall = PillController.grownFrame(old: old, face: CGSize(width: 224, height: 200), plainSize: plain, scale: 1, visible: visible)
        #expect(tall.minY == old.minY && tall.maxY <= visible.maxY && tall.height >= 20 + 200 + 30 + 16)
        // A face that can never fit moves the panel down rather than clipping the capsule.
        let huge = PillController.grownFrame(old: old, face: CGSize(width: 224, height: 270), plainSize: plain, scale: 1, visible: visible)
        #expect(huge.height >= 20 + 270 + 30 + 16)
        // Off the side of a narrow screen.
        let side = PillController.grownFrame(
            old: CGRect(x: -100, y: -8, width: 256, height: 100), face: CGSize(width: 224, height: 100), plainSize: plain, scale: 1, visible: visible
        )
        #expect(side.minX >= visible.minX)
    }

    // MARK: F7

    @Test func theUndoClockSurvivesASkinChangeMidCard() throws {
        let rig = CardRig(skin: "matrix")
        rig.presenter.present(.cancelled())
        let merged = try #require(rig.cards.mergedView.countdownStart)
        // Matrix to Classic while the card is up: the card moves to its own panel.
        rig.cards.anchor = { .init(midX: 500, top: 100, visible: CGRect(x: 0, y: 0, width: 1000, height: 800)) }
        rig.cards.render(rig.presenter.state)
        #expect(!rig.cards.isMerged)
        #expect(rig.cards.view.countdownStart == merged)
        rig.finish()
    }
}
