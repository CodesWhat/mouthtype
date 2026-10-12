import Testing
@testable import MouthtypeMac

@Suite struct PillLayoutTests {
    private let assets = try! PillAssets.loadHiFi()

    @Test func everyRectLiesInsideThePill() {
        let layout = assets.layout
        let size = layout.size
        #expect(size == PillLayout.Size(w: 146, h: 32))
        #expect(layout.window.isInside(size))
        for (name, sprite) in layout.sprites {
            #expect(sprite.rect.isInside(size), "\(name)")
        }
        for column in layout.meter.segments {
            for segment in column { #expect(segment.isInside(size)) }
        }
        for slot in [layout.text.timer, layout.text.timerLocked, layout.text.message] {
            let height = layout.fonts[slot.font]?.cellHeight ?? 0
            #expect(PillLayout.Rect(x: slot.x, y: slot.y, w: slot.maxWidth, h: height).isInside(size))
        }
        #expect(assets.chassis.width == size.w && assets.chassis.height == size.h)
    }

    @Test func meterSegmentsStayInsideTheWindowAndNeverOverlap() {
        let layout = assets.layout
        let all = layout.meter.segments.flatMap { $0 }
        #expect(layout.meter.segments.count == layout.meter.columns)
        #expect(layout.meter.segments.allSatisfy { $0.count == layout.meter.segmentsPerColumn })
        #expect(layout.meter.rowTiers.count == layout.meter.segmentsPerColumn)
        for segment in all {
            let w = layout.window
            #expect(segment.x >= w.x && segment.y >= w.y && segment.x + segment.w <= w.x + w.w && segment.y + segment.h <= w.y + w.h)
        }
        for i in all.indices {
            for j in all.indices where j > i { #expect(!all[i].overlaps(all[j])) }
        }
    }

    @Test func textSlotsLieInsideTheWindowAndTheTimerFits() throws {
        let layout = assets.layout
        let w = layout.window
        for slot in [layout.text.timer, layout.text.timerLocked, layout.text.message] {
            #expect(slot.x >= w.x && slot.x + slot.maxWidth <= w.x + w.w)
        }
        let f3 = try #require(assets.fonts[layout.text.timerLocked.font])
        #expect(f3.width(of: PillTimeline.timerText(seconds: 599)) <= layout.text.timerLocked.maxWidth)
        let padlock = try #require(layout.sprites["padlock"])
        #expect(padlock.x + padlock.w <= layout.text.timerLocked.x)
    }

    @Test func everyStateSpriteIsPresentAndStatePairsShareARect() {
        let sprites = assets.layout.sprites
        for name in ["talk_up", "talk_down", "led_off", "led_on", "led_glow", "cancel", "cancel_lit", "stop", "stop_lit", "padlock"] {
            #expect(sprites[name] != nil && assets.sprites[name] != nil, "\(name)")
        }
        for (a, b) in [("talk_up", "talk_down"), ("led_off", "led_on"), ("cancel", "cancel_lit"), ("stop", "stop_lit")] {
            #expect(sprites[a]?.rect == sprites[b]?.rect)
        }
        for (name, sprite) in sprites {
            #expect(assets.sprites[name]?.width == sprite.w && assets.sprites[name]?.height == sprite.h)
        }
    }

    @Test func colorsParseFromHex() {
        let c = PillLayout.color(hex: assets.layout.colors.segmentNormal)
        #expect(c.numberOfComponents == 4)
        #expect(PillLayout.color(hex: "#ff0000").components?.prefix(3) == [1, 0, 0])
    }
}

@Suite struct PillTimelineTests {
    @Test func timerTextIsMinutesAndPaddedSecondsAndClamps() {
        #expect(PillTimeline.timerText(seconds: 0) == "0:00")
        #expect(PillTimeline.timerText(seconds: 7) == "0:07")
        #expect(PillTimeline.timerText(seconds: 84) == "1:24")
        #expect(PillTimeline.timerText(seconds: 599) == "9:59")
        #expect(PillTimeline.timerText(seconds: 5000) == "9:59")
        #expect(PillTimeline.timerText(seconds: -4) == "0:00")
    }

    @Test func ledIsSteadyWhileHeldAndBlinksAboutOnceASecondWhenLocked() {
        #expect(PillTimeline.ledOn(elapsed: 3.7, locked: false))
        #expect(PillTimeline.ledOn(elapsed: 0.1, locked: true))
        #expect(!PillTimeline.ledOn(elapsed: 0.6, locked: true))
        #expect(PillTimeline.ledOn(elapsed: 1.1, locked: true))
    }

    @Test func marqueeCentresWhatFitsAndScrollsWhatDoesNot() {
        #expect(Marquee.layout(textWidth: 53, windowWidth: 64) == .centered(offset: 5))
        #expect(Marquee.layout(textWidth: 64, windowWidth: 64) == .centered(offset: 0))
        #expect(Marquee.layout(textWidth: 143, windowWidth: 64) == .scrolling(distance: 79))
    }

    @Test func marqueeHoldsScrollsOnceAndStopsAtTheEnd() {
        #expect(Marquee.offset(distance: 79, at: 0) == 0)
        #expect(Marquee.offset(distance: 79, at: Marquee.hold) == 0)
        #expect(Marquee.offset(distance: 79, at: Marquee.hold + 1) == -30)
        #expect(Marquee.offset(distance: 79, at: 100) == -79)
        #expect(Marquee.duration(distance: 79) > Marquee.hold * 2)
    }
}
