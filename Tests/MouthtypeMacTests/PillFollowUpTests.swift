import AppKit
import Testing
@testable import MouthtypeMac

private let longDetail = Array(repeating: "The speech engine stopped part way through and nothing could be recovered from it.", count: 12)
    .joined(separator: " ")

@MainActor
@Suite struct PillFollowUpTests {
    @Test func theLargeMessageFaceIsTwentyEightPointsInAnyFont() {
        for choice in [TextFontChoice.systema, .system, .rounded, .serif, .mono] {
            let typography = Typography(choice: choice)
            #expect(typography.font(.pillMessage, scale: 2).pointSize == 28)
            #expect(typography.font(.pillDetail, scale: 2).pointSize == 22)
        }
        #expect(Typography(choice: .system).font(.pillMessage).pointSize == 12)
    }

    @Test(arguments: [PillScale.standard, .large])
    func aLongClassicMessageStopsAtTheCapAndScrollsWithoutTruncating(scale: PillScale) {
        _ = NSApplication.shared
        let view = ClassicPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale)), size: scale)
        view.appear(reduceMotion: true)
        view.showMessage(PillMessage("Transcription failed", detail: longDetail, isError: true), overRecording: false)
        let cap = PillGeometry.maxPillSize.height * scale.factor
        #expect(view.messageSize.height == cap)
        #expect(view.messageScrollDistance > 0)
        view.setMessageOffset(-view.messageScrollDistance)
        let shown = view.messageLines.filter(\.isDetail).map(\.text).joined(separator: " ")
        #expect(shown == longDetail && !shown.contains("\u{2026}"))
    }

    @Test func aShortClassicMessageDoesNotScroll() {
        _ = NSApplication.shared
        let view = ClassicPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize), size: .standard)
        view.appear(reduceMotion: true)
        view.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        #expect(view.messageScrollDistance == 0)
    }

    @Test func theLivePreviewReadoutScalesWithThePillSize() {
        _ = NSApplication.shared
        for (size, factor) in [(PillSize.standard, CGFloat(1)), (.large, 2)] {
            let defaults = UserDefaults(suiteName: "pill-followup-\(UUID().uuidString)")!
            PillSizePreference.set(size, in: defaults)
            let pill = PillController(level: { .silence }, defaults: defaults)
            #expect(pill.previewView.frame.width == ClassicPillLayout.messageCap * factor)
            #expect(pill.host.bounds.contains(pill.previewView.frame))
        }
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal])
    func theLampAnimationIsGoneOnceThePillDisappears(kind: PillSkinKind) throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let skin = try #require(
            try PillSkinFactory.make(kind, frame: NSRect(origin: .zero, size: PillGeometry.panelSize), scale: .standard) as? SquirclePillView
        )
        skin.reduceMotionOverride = false
        skin.appear(reduceMotion: false)
        skin.showRecording(locked: false)
        #expect(skin.lampAnimation != nil)
        skin.disappear(reduceMotion: false) {}
        #expect(skin.lampAnimation == nil && skin.lampMotion == .steady)
    }

    @Test func theCardClearsAMessageThatHasADetailLine() throws {
        let pill = makePillController(skin: .classic)
        let screen = PillPlacement.Screen(
            frame: CGRect(x: 0, y: 0, width: 1500, height: 900), visibleFrame: CGRect(x: 0, y: 0, width: 1500, height: 870)
        )
        pill.screensSource = { [screen] }
        pill.pointerSource = { CGPoint(x: 100, y: 100) }
        let resting = try #require(pill.cardAnchor())
        pill.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), duration: 60)
        let over = try #require(pill.cardAnchor())
        #expect(pill.skin.messageSize.height > ClassicPillLayout.height)
        #expect(over.top - resting.top == pill.skin.messageSize.height - ClassicPillLayout.height)
        pill.hide()
    }
}

@MainActor
@Suite struct GlassFollowUpTests {
    private let file = URL(fileURLWithPath: "/tmp/wallpaper.heic")
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)

    @Test func aSlowMeasurementOfAnOldRegionNeverOverwritesTheCurrentOne() async {
        let gate = DispatchSemaphore(value: 0)
        let cache = GlassBackdropCache(
            measure: { _, _, region in
                if region.minX == 100 {
                    _ = gate.wait(timeout: .now() + 5)
                    return .init(luminance: 0.9, spread: 0)
                }
                return .init(luminance: 0.1, spread: 0)
            },
            modificationDate: { _ in nil }
        )
        let old = CGRect(x: 100, y: 20, width: 100, height: 28)
        let current = CGRect(x: 400, y: 20, width: 100, height: 28)
        let slow = cache.prewarm(screen: 1, file: file, screenFrame: frame, region: old)
        await cache.prewarm(screen: 1, file: file, screenFrame: frame, region: current)?.value
        gate.signal()
        await slow?.value
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: current) == .ready(.init(luminance: 0.1, spread: 0)))
    }

    @Test func theHeldRegionSitsOnWholePointsLikeThePanel() {
        let screen = CGRect(x: 0, y: 0, width: 1511, height: 982)
        for size in [PillSize.standard, .large] {
            let region = GlassBackdropCache.heldRegion(frame: screen, visibleFrame: screen, backing: 2, size: size)
            let scale = size.resolved(visibleWidth: screen.width)
            let body = GlassPillView.heldBodyRegion(bounds: PillGeometry.panelSize(for: scale), size: scale, backing: 2)
            let dx = region.minX - body.minX, dy = region.minY - body.minY
            #expect(dx == dx.rounded() && dy == dy.rounded())
        }
    }
}

@Suite struct MarqueeReduceMotionTests {
    @Test func reduceMotionHoldsThenJumpsToTheEnd() {
        #expect(Marquee.offset(distance: 90, at: 0.3, reduceMotion: true) == 0)
        #expect(Marquee.offset(distance: 90, at: Marquee.hold + 0.01, reduceMotion: true) == -90)
        #expect(Marquee.duration(distance: 90, reduceMotion: true) == 2 * Marquee.hold)
        #expect(Marquee.offset(distance: 90, at: Marquee.hold + 1) == -30)
    }
}
