import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PillSizeSettingTests {
    typealias L = ClassicPillLayout

    private func defaults() -> UserDefaults {
        UserDefaults(suiteName: "pill-size-setting-\(UUID().uuidString)")!
    }

    // MARK: Automatic

    @Test func automaticIsLargeFromTwoThousandPointsWide() {
        #expect(PillSize.automatic.resolved(visibleWidth: 1999) == .standard)
        #expect(PillSize.automatic.resolved(visibleWidth: 1999.5) == .standard)
        #expect(PillSize.automatic.resolved(visibleWidth: 2000) == .large)
        #expect(PillSize.automatic.resolved(visibleWidth: 3440) == .large)
        #expect(PillSize.automatic.resolved(visibleWidth: 0) == .standard)
    }

    @Test func anExplicitSizeIgnoresTheScreen() {
        for width in [CGFloat(0), 1999, 2000, 5120] {
            #expect(PillSize.standard.resolved(visibleWidth: width) == .standard)
            #expect(PillSize.large.resolved(visibleWidth: width) == .large)
        }
    }

    @Test func automaticIsTheDefaultAndTheScreenIsThePointersScreen() {
        #expect(PillSizePreference.current(defaults()) == .automatic)
        let small = PillPlacement.Screen(frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visibleFrame: CGRect(x: 0, y: 70, width: 1512, height: 880))
        let wide = PillPlacement.Screen(frame: CGRect(x: 1512, y: 0, width: 3440, height: 1440), visibleFrame: CGRect(x: 1512, y: 0, width: 3440, height: 1400))
        let onWide = PillPlacement.screen(pointer: CGPoint(x: 2000, y: 500), screens: [small, wide])
        let onSmall = PillPlacement.screen(pointer: CGPoint(x: 100, y: 500), screens: [small, wide])
        #expect(onWide == wide && onSmall == small)
        #expect(PillPlacement.screen(pointer: CGPoint(x: -5000, y: 0), screens: [small, wide]) == small)
        #expect(PillPlacement.screen(pointer: .zero, screens: []) == nil)
        #expect(PillSize.automatic.resolved(visibleWidth: onWide?.visibleFrame.width ?? 0) == .large)
        #expect(PillSize.automatic.resolved(visibleWidth: onSmall?.visibleFrame.width ?? 0) == .standard)
    }

    @Test func theLargePanelGrowsWithThePill() {
        let standard = PillGeometry.panelSize(for: .standard)
        let large = PillGeometry.panelSize(for: .large)
        #expect(standard == PillGeometry.panelSize && standard == CGSize(width: 368, height: 200))
        #expect(large == CGSize(width: 688, height: 360))
    }

    // MARK: Hi-Fi

    @Test func hiFiDrawsAtWholeNumberArtScales() throws {
        let assets = try PillAssets.loadHiFi()
        for (scale, size) in [(PillScale.standard, CGSize(width: 146, height: 32)), (.large, CGSize(width: 292, height: 64))] {
            let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
            let view = HiFiPillView(frame: frame, assets: assets, size: scale)
            #expect(view.artScale == scale.factor && view.pillSize == size)
            #expect(view.artScale == view.artScale.rounded())
        }
    }

    // MARK: Migration

    @Test func aSavedLargeHiFiSizeBecomesTheLargePillAndTheOldKeyGoes() {
        let preferences = defaults()
        preferences.set(2, forKey: "hiFiPillSize")
        #expect(PillSizePreference.current(preferences) == .large)
        #expect(preferences.string(forKey: "pillSize") == "large")
        #expect(preferences.object(forKey: "hiFiPillSize") == nil)
    }

    @Test func anExplicitStandardHiFiSizeStaysStandard() {
        let preferences = defaults()
        preferences.set(1, forKey: "hiFiPillSize")
        #expect(PillSizePreference.current(preferences) == .standard)
        #expect(preferences.string(forKey: "pillSize") == "standard")
        #expect(preferences.object(forKey: "hiFiPillSize") == nil)
    }

    @Test func anythingElseSavedBecomesAutomaticAndTheOldKeyGoes() {
        for legacy in [0, 3, -2, 99] {
            let preferences = defaults()
            preferences.set(legacy, forKey: "hiFiPillSize")
            #expect(PillSizePreference.current(preferences) == .automatic)
            #expect(preferences.string(forKey: "pillSize") == "automatic")
            #expect(preferences.object(forKey: "hiFiPillSize") == nil)
        }
    }

    @Test func migrationNeverOverwritesAChoiceAlreadyMade() {
        let preferences = defaults()
        preferences.set("standard", forKey: "pillSize")
        preferences.set(2, forKey: "hiFiPillSize")
        #expect(PillSizePreference.current(preferences) == .standard)
        #expect(preferences.object(forKey: "hiFiPillSize") == nil)
    }

    @Test func nothingIsWrittenWhenThereWasNothingToMigrate() {
        let preferences = defaults()
        _ = PillSizePreference.current(preferences)
        #expect(preferences.object(forKey: "pillSize") == nil && preferences.object(forKey: "hiFiPillSize") == nil)
    }

    @Test func settingASizeRemovesAnyLeftoverOldKey() {
        let preferences = defaults()
        preferences.set(2, forKey: "hiFiPillSize")
        PillSizePreference.set(.standard, in: preferences)
        #expect(preferences.object(forKey: "hiFiPillSize") == nil && PillSizePreference.current(preferences) == .standard)
    }

    @Test func aMigratedLargeSizeBuildsTheLargePill() throws {
        let preferences = defaults()
        preferences.set(2, forKey: "hiFiPillSize")
        preferences.set("hifi", forKey: "pillSkin")
        let pill = PillController(level: { .silence }, defaults: preferences)
        #expect(pill.pillScale == .large)
        #expect(try #require(pill.skin as? HiFiPillView).pillSize == CGSize(width: 292, height: 64))
    }

    @Test func theCardMessageIsHeldClickThroughAndOnlyTheCardTakesItDown() {
        let pill = PillController(level: { .silence }, defaults: defaults())
        let message = PillMessage("Your text is safe", isError: true)
        pill.showCardMessage(message)
        #expect(pill.state == .message(message) && pill.cardHeld && pill.panel.ignoresMouseEvents)
        pill.showCardMessage(PillMessage("The field didn't change", isError: true))
        #expect(pill.state == .message(PillMessage("The field didn't change", isError: true)))
        pill.hideCardMessage()
        #expect(pill.state == .hidden && !pill.cardHeld)
        // Something newer on the pill is not the card's to take down.
        pill.showCardMessage(message)
        pill.showProcessing()
        pill.hideCardMessage()
        #expect(pill.state == .processing)
        pill.hide()
    }

    // MARK: Classic geometry

    @Test func classicLargeIsTwiceTheStandardGeometry() {
        let s = L.Metrics.standard, l = L.Metrics.large
        #expect(s.height == 28 && l.height == 56)
        #expect(s.barWidth == 2.25 && l.barWidth == 4.5)
        #expect(s.barPitch == 4.25 && l.barPitch == 8.5)
        #expect(s.maxBarHeight == 14.25 && l.maxBarHeight == 28.5)
        #expect(s.controlDiameter == 18 && l.controlDiameter == 36)
        #expect(l.messagePadding == 2 * s.messagePadding && l.barSidePadding == 2 * s.barSidePadding)
        #expect(l.controlInset == 2 * s.controlInset && l.controlGap == 2 * s.controlGap)
        #expect(l.messageVerticalPadding == 2 * s.messageVerticalPadding && l.messageCap == 2 * s.messageCap)
        #expect(l.dotWidth == l.height && l.cornerRadius == 28)
    }

    @Test func classicLargeMessageFacesAre28And22Points() {
        let typography = Typography.current()
        for (role, size) in [(TextRole.pillMessage, CGFloat(28)), (.pillDetail, 22)] {
            let standard = typography.font(role)
            let large = typography.font(role, scale: 2)
            // The large message face is the Systema design scaled in every font, so only the detail is a plain 2x elsewhere.
            if role == .pillDetail || typography.effectiveChoice == .systema { #expect(large.pointSize == 2 * standard.pointSize) }
            #expect(large.pointSize == size)
        }
    }

    @Test func barsStayOnEvenDevicePixelsAtBothBackingScalesAndSizes() {
        for metrics in [L.Metrics.standard, .large] {
            for scale in [CGFloat(1), 2] {
                let m = L.barMetrics(scale: scale, metrics: metrics)
                let range = L.barHeightRange(scale: scale, metrics: metrics)
                for value in [m.width, m.pitch, range.lowerBound, range.upperBound] {
                    let px = value * scale
                    #expect(px == px.rounded() && Int(px) % 2 == 0, "\(value) pt at \(scale)x, factor \(metrics.factor)")
                }
                #expect(range.lowerBound == m.width)
                for i in 0...20 {
                    let px = L.barHeight(fraction: Float(i) / 20, scale: scale, metrics: metrics) * scale
                    #expect(px == px.rounded() && Int(px) % 2 == 0)
                    #expect(range.contains(px / scale))
                }
            }
        }
    }

    @Test func largeBarsAreExactlyTwiceTheSnappedStandardBarsAtEveryBackingScale() {
        for scale in [CGFloat(1), 2, 3] {
            let s = L.barMetrics(scale: scale), l = L.barMetrics(scale: scale, metrics: .large)
            #expect(l.width == 2 * s.width && l.pitch == 2 * s.pitch)
            #expect(L.barHeightRange(scale: scale, metrics: .large).upperBound == 2 * L.barHeightRange(scale: scale).upperBound)
        }
        // Standard snaps 2.25 / 4.25 / 14.25 pt to 2 / 4 / 14, so Large is 4 / 8 / 28 at 1x and 2x.
        for scale in [CGFloat(1), 2] {
            let l = L.barMetrics(scale: scale, metrics: .large)
            #expect(l.width == 4 && l.pitch == 8 && L.barHeightRange(scale: scale, metrics: .large).upperBound == 28)
        }
    }

    @Test func largeCapsulesHoldTheBarsWithDoubledPaddingOnTheGrid() {
        for scale in [CGFloat(1), 2] {
            for mode in [L.Mode.hold, .locked, .processing, .message(width: 200, height: 56)] {
                let px = L.capsuleWidth(mode, scale: scale, metrics: .large) * scale
                #expect(px == px.rounded() && Int(px) % 2 == 0)
            }
            let hold = L.holdWidth(scale: scale, metrics: .large)
            let bars = L.barsSpan(scale: scale, metrics: .large)
            #expect(hold >= bars + 2 * 18 && hold < bars + 2 * 18 + 2)
            #expect(L.capsuleHeight(.hold, metrics: .large) == 56 && L.capsuleHeight(.hold) == 28)
            let capsule = L.capsuleFrame(width: hold, height: 56, bounds: PillGeometry.panelSize(for: .large), bottomMargin: 20, scale: scale)
            let tallest = [CGFloat](repeating: L.barHeightRange(scale: scale, metrics: .large).upperBound, count: 10)
            let frames = L.barFrames(capsule: capsule, heights: tallest, scale: scale, metrics: .large)
            #expect(frames.allSatisfy { capsule.contains($0) })
            #expect(frames.first!.minX - capsule.minX == capsule.maxX - frames.last!.maxX)
            for frame in frames {
                for v in [frame.minX, frame.width, frame.height] { #expect((v * scale) == (v * scale).rounded()) }
            }
            let locked = L.capsuleFrame(width: L.lockedWidth(scale: scale, metrics: .large), height: 56, bounds: PillGeometry.panelSize(for: .large), bottomMargin: 20, scale: scale)
            let controls = L.controlFrames(capsule: locked, metrics: .large)
            #expect(controls[.cancel]?.width == 36 && controls[.stop]?.height == 36)
            #expect(locked.contains(controls[.cancel]!) && locked.contains(controls[.stop]!))
        }
    }

    @Test func largeMessagesWrapAtTheDoubledCapAndUseTheDoubledMinimumHeight() {
        let measure: (String, Bool) -> CGFloat = { text, _ in CGFloat(text.count) * 12 }
        let one = L.messageBlock(headline: "Cancelled", detail: nil, headlineLineHeight: 34, detailLineHeight: 26, scale: 2, metrics: .large, measure: measure)
        #expect(one.height == 56 && one.lines.count == 1 && one.width <= 640 && one.width >= 128)
        let two = L.messageBlock(headline: "Paste failed", detail: "Your text is safe", headlineLineHeight: 34, detailLineHeight: 26, scale: 2, metrics: .large, measure: measure)
        #expect(two.lines.count == 2 && two.height >= 56 + 0 && two.height >= 34 + 26 + 2 + 28)
        let long = L.messageBlock(headline: String(repeating: "word ", count: 40), detail: nil, headlineLineHeight: 34, detailLineHeight: 26, scale: 2, metrics: .large, measure: measure)
        #expect(long.width > 320 && long.width <= 640 && long.lines.count > 1)
        #expect(long.lines.allSatisfy { measure($0.text, false) <= 640 - 64 })
    }

    @Test func theClassicViewBuildsAtBothSizesAndDrawsTheLargePillTwiceAsTall() throws {
        for scale in [PillScale.standard, .large] {
            let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
            let view = ClassicPillView(frame: frame, size: scale)
            view.appear(reduceMotion: true)
            view.showRecording(locked: true)
            let frames = view.controlFrames
            let cancel = try #require(frames[.cancel])
            #expect(cancel.width == 18 * scale.factor)
            view.showMessage(PillMessage("Cancelled"), overRecording: false)
            #expect(view.messageSize.height == 28 * scale.factor)
        }
    }

    @Test func pillControllerSizesPanelAndSkinForTheResolvedScale() throws {
        let preferences = defaults()
        preferences.set("large", forKey: "pillSize")
        let large = PillController(level: { .silence }, defaults: preferences)
        #expect(large.pillScale == .large && large.panel.contentView?.frame.size == PillGeometry.panelSize(for: .large))
        #expect((large.skin as? ClassicPillView)?.pillScale == .large)
        preferences.set("standard", forKey: "pillSize")
        large.setSkin(.classic)
        large.showRecording()
        defer { large.hide() }
        #expect(large.pillScale == .standard && (large.skin as? ClassicPillView)?.pillScale == .standard)
        #expect(large.panel.frame.size == PillGeometry.panelSize)
    }

    // MARK: Delivery card

    @Test func theDismissControlIsTheMinimumTarget() {
        #expect(CardLayout.dismissSize == 24 && CardLayout.dismissSize >= PillHit.minTarget)
        let frames = CardLayout.make(.init(
            headerTextHeight: 16, headerLineHeight: 16, transcriptTextHeight: 18, transcriptLineHeight: 18,
            buttonLabelWidths: [30], hasCountdownBar: false
        ))
        #expect(frames.dismiss.size == CGSize(width: 24, height: 24) && frames.dismiss.minY >= 0)
        #expect(frames.dismiss.maxX == CardLayout.width - CardLayout.insets.side)
        #expect(!frames.dismiss.intersects(frames.header))
    }

    @Test func thePillUnderACardSaysTheDetailNotTheHeader() {
        for card in [DeliveryCard.pasteFailed("hello"), .secure("hello"), .nowhere("hello")] {
            let message = card.pillMessage
            #expect(message == PillMessage("Your text is safe", isError: true))
            #expect(message?.headline != card.header)
        }
        #expect(DeliveryCard.recovered("hello").pillMessage == PillMessage("Your text is safe", isError: false))
        #expect(DeliveryCard.notLanded("hello").pillMessage == PillMessage("The field didn't change", isError: true))
        #expect(DeliveryCard.micDisconnected(seconds: 4).pillMessage == PillMessage("4 seconds recorded", isError: true))
        #expect(DeliveryCard.limitWarning(stopsAfter: 1200).pillMessage?.headline == "Recording stops at 20 minutes")
    }

    @Test func aCardWithNothingToAddLeavesThePillQuiet() {
        #expect(DeliveryCard.cancelled().pillMessage == nil)
        #expect(DeliveryCard.rememberSpelling(SpellingPair(heard: "a", corrected: "b")).pillMessage == nil)
    }
}
