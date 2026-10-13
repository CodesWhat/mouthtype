import AppKit
import Testing
@testable import MouthtypeMac

@MainActor
@Suite struct PillSkinSelectionTests {
    private func freshDefaults() -> UserDefaults { UserDefaults(suiteName: "pill-skin-\(UUID().uuidString)")! }

    @Test func classicIsTheDefaultAndChoicesPersist() {
        let defaults = freshDefaults()
        #expect(PillSkinPreference.current(defaults) == .classic)
        PillSkinPreference.set(.hifi, in: defaults)
        #expect(PillSkinPreference.current(defaults) == .hifi)
        #expect(defaults.string(forKey: "pillSkin") == "hifi")
        defaults.set("nonsense", forKey: "pillSkin")
        #expect(PillSkinPreference.current(defaults) == .classic)
    }

    @Test func controllerStartsOnTheSavedSkin() {
        #expect(makePillController().skin is ClassicPillView)
        #expect(makePillController(skin: .hifi).skin is HiFiPillView)
        #expect(makePillController(skin: .hifi).skinKind == .hifi)
    }

    @Test func switchingWhileHiddenAppliesAtOnce() {
        let controller = makePillController()
        controller.setSkin(.hifi)
        #expect(controller.skinKind == .hifi && controller.skin is HiFiPillView)
        #expect(controller.skin.superview === controller.host)
        controller.setSkin(.classic)
        #expect(controller.skin is ClassicPillView)
    }

    @Test func switchingDuringARecordingWaitsForTheNextShow() {
        let controller = makePillController()
        controller.showRecording()
        controller.setSkin(.hifi)
        #expect(controller.skinKind == .classic && controller.skin is ClassicPillView)
        controller.hide()
        controller.showRecording()
        #expect(controller.skinKind == .hifi && controller.skin is HiFiPillView)
        controller.hide()
    }

    @Test func menuListsBothSkinsWithTheCurrentOneChecked() {
        let defaults = freshDefaults()
        var picked: [PillSkinKind] = []
        let section = PillSkinMenuSection(defaults: defaults, onSelect: { picked.append($0) })
        let submenu = section.items[0].submenu
        #expect(section.items[0].title == "Pill Style")
        #expect(submenu?.items.map(\.title) == ["Classic", "Hi-Fi"])
        #expect(submenu?.items.map(\.state) == [.on, .off])
        let hifi = submenu!.items[1]
        _ = hifi.target?.perform(hifi.action, with: hifi)
        #expect(picked == [.hifi])
        #expect(PillSkinPreference.current(defaults) == .hifi)
        #expect(submenu?.items.map(\.state) == [.off, .on])
    }
}

@MainActor
@Suite struct ClassicPillLayoutTests {
    typealias L = ClassicPillLayout

    @Test func capsuleWidthPerState() {
        #expect(L.capsuleWidth(.hold, scale: 2) == 56)
        #expect(L.capsuleWidth(.processing, scale: 2) == 56)
        #expect(L.capsuleWidth(.hold, scale: 1) == 56)
        #expect(L.capsuleWidth(.locked, scale: 2) > L.capsuleWidth(.hold, scale: 2))
        #expect(L.capsuleWidth(.locked, scale: 2) == L.lockedWidth(scale: 2))
        for scale in [CGFloat(1), 2] {
            for mode in [L.Mode.hold, .locked, .processing, .message(width: 120, height: 28)] {
                let px = L.capsuleWidth(mode, scale: scale) * scale
                #expect(px == px.rounded() && Int(px) % 2 == 0)
            }
        }
    }

    @Test func holdCapsuleHugsTheBarsWithPaddingNearTheVerticalPadding() {
        for scale in [CGFloat(1), 2] {
            let capsule = L.capsuleFrame(width: L.capsuleWidth(.hold, scale: scale), bounds: CGSize(width: 368, height: 72), bottomMargin: 20, scale: scale)
            let tallest = [CGFloat](repeating: L.barHeightRange(scale: scale).upperBound, count: 10)
            let bars = L.barFrames(capsule: capsule, heights: tallest, scale: scale)
            let side = bars.first!.minX - capsule.minX
            #expect(side == capsule.maxX - bars.last!.maxX)
            let vertical = bars[4].minY - capsule.minY
            #expect(side >= 8 && side <= 10, "side padding \(side)")
            #expect(abs(side - vertical) <= 3, "side \(side) against vertical \(vertical)")
            // A true capsule: the end radius is half the height, so the width is at least the height.
            #expect(capsule.width >= capsule.height && L.cornerRadius == capsule.height / 2)
        }
    }

    @Test func lockedCapsuleHasNoDeadSpaceBetweenControlsAndBars() {
        let capsule = L.capsuleFrame(width: L.lockedWidth(scale: 2), bounds: CGSize(width: 368, height: 72), bottomMargin: 20, scale: 2)
        let controls = L.controlFrames(capsule: capsule)
        let bars = L.barFrames(capsule: capsule, heights: [CGFloat](repeating: 6, count: 10), scale: 2)
        let gap = bars.first!.minX - controls[.cancel]!.maxX
        #expect(gap >= 8 && gap <= 12, "gap \(gap)")
        #expect(gap == controls[.stop]!.minX - bars.last!.maxX)
        #expect(L.lockedWidth(scale: 2) == 104)
    }

    @Test func barMetricsLandOnTheDeviceGrid() {
        for scale in [CGFloat(1), 2] {
            let m = L.barMetrics(scale: scale)
            #expect(Int(m.width * scale) % 2 == 0 && Int(m.pitch * scale) % 2 == 0)
            let range = L.barHeightRange(scale: scale)
            #expect(range.lowerBound == m.width)
            #expect(Int(range.upperBound * scale) % 2 == 0)
        }
    }

    @Test func barHeightsRunFromDotsToFullAndNeverLeaveTheRange() {
        let range = L.barHeightRange(scale: 2)
        #expect(L.barHeight(fraction: 0, scale: 2) == range.lowerBound)
        #expect(L.barHeight(fraction: 0.02, scale: 2) == range.lowerBound)
        #expect(L.barHeight(fraction: 1, scale: 2) == range.upperBound)
        #expect(L.barHeight(fraction: 0.5, scale: 2) > range.lowerBound + 4)
        // Linear: half the fraction is about half the travel.
        let mid = L.barHeight(fraction: 0.5, scale: 2)
        #expect(abs(mid - (range.lowerBound + range.upperBound) / 2) <= 1)
        for f in [Float.nan, .infinity, -4, 9] { #expect(range.contains(L.barHeight(fraction: f, scale: 2))) }
        var last: CGFloat = 0
        for i in 0...100 {
            let h = L.barHeight(fraction: Float(i) / 100, scale: 2)
            #expect(h >= last)
            last = h
        }
    }

    @Test func barFramesAreCentredSymmetricAndOnTheGrid() {
        let capsule = L.capsuleFrame(width: 56, bounds: CGSize(width: 368, height: 72), bottomMargin: 20, scale: 2)
        #expect(capsule.midX == 184 && capsule.minY == 20 && capsule.height == 28)
        let heights = (0..<10).map { CGFloat($0 % 2 == 0 ? 6 : 14) }
        let frames = L.barFrames(capsule: capsule, heights: heights, scale: 2)
        #expect(frames.count == 10)
        for frame in frames {
            #expect(frame.midY == capsule.midY)
            for v in [frame.minX, frame.minY, frame.width, frame.height] { #expect((v * 2) == (v * 2).rounded()) }
        }
        for i in 0..<5 { #expect(frames[i].midX + frames[9 - i].midX == 2 * capsule.midX) }
        #expect(frames.allSatisfy { capsule.contains($0) })
    }

    @Test func controlFramesSitAtTheEndsAndInsideTheLockedCapsule() {
        let capsule = L.capsuleFrame(width: L.lockedWidth(scale: 2), bounds: CGSize(width: 368, height: 72), bottomMargin: 20, scale: 2)
        let frames = L.controlFrames(capsule: capsule)
        let cancel = frames[.cancel]!, stop = frames[.stop]!
        #expect(cancel.width == 18 && cancel.height == 18 && stop.width == 18)
        #expect(cancel.minX - capsule.minX == capsule.maxX - stop.maxX)
        #expect(cancel.midY == capsule.midY && stop.midY == capsule.midY)
        #expect(capsule.contains(cancel) && capsule.contains(stop))
        let bars = L.barFrames(capsule: capsule, heights: [CGFloat](repeating: 6, count: 10), scale: 2)
        #expect(bars.first!.minX > cancel.maxX && bars.last!.maxX < stop.minX)
    }

    @Test func processingWaveStaysLowAndMoves() {
        let a = L.processingFractions(time: 0, count: 10)
        let b = L.processingFractions(time: 0.4, count: 10)
        #expect(a != b)
        #expect((a + b).allSatisfy { $0 > 0.05 && $0 < 0.35 })
    }
}

@MainActor
@Suite struct PillHitTests {
    @Test func targetsGrowToAtLeast24ButNeverShrink() {
        let small = PillHit.target(for: CGRect(x: 100, y: 10, width: 11, height: 11))
        #expect(small.width == 24 && small.height == 24 && small.midX == 105.5 && small.midY == 15.5)
        let big = PillHit.target(for: CGRect(x: 0, y: 0, width: 30, height: 26))
        #expect(big.size == CGSize(width: 30, height: 26))
    }

    @Test func pointsHitInsideThePaddingAndMissOutside() {
        let frames: [PillControl: CGRect] = [.cancel: CGRect(x: 10, y: 10, width: 18, height: 18)]
        #expect(PillHit.control(at: CGPoint(x: 19, y: 19), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: 8, y: 19), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: 7.5, y: 19), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: 6.5, y: 19), frames: frames) == nil)
        #expect(PillHit.control(at: CGPoint(x: 19, y: 40), frames: frames) == nil)
        #expect(PillHit.control(at: CGPoint(x: 19, y: 19), frames: [:]) == nil)
    }

    @Test func overlappingPaddedTargetsGoToTheNearerCentre() {
        let frames: [PillControl: CGRect] = [
            .cancel: CGRect(x: 117, y: 7, width: 11, height: 11), .stop: CGRect(x: 131, y: 7, width: 11, height: 11),
        ]
        #expect(PillHit.control(at: CGPoint(x: 125, y: 12), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: 133, y: 12), frames: frames) == .stop)
        #expect(PillHit.control(at: CGPoint(x: 112, y: 12), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: 100, y: 12), frames: frames) == nil)
    }

    @Test(arguments: PillSkinKind.allCases) func controlsExistOnlyWhileLockedAndShowingTheMeter(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        #expect(controller.skin.controlFrames.isEmpty)
        controller.showRecording()
        #expect(controller.skin.controlFrames.isEmpty)
        controller.showHandsFree()
        let frames = controller.skin.controlFrames
        #expect(Set(frames.keys) == [.cancel, .stop])
        let bounds = controller.host.bounds
        for frame in frames.values {
            #expect(bounds.contains(frame))
            let target = PillHit.target(for: frame)
            #expect(target.width >= 24 && target.height >= 24)
        }
        #expect(frames[.cancel]!.midX < frames[.stop]!.midX)
        controller.showHandsFreeNotice("1 minute left", duration: 5)
        #expect(controller.skin.controlFrames.isEmpty)
        controller.showProcessing()
        #expect(controller.skin.controlFrames.isEmpty)
        controller.hide()
    }

    @Test func hiFiCapsAre11PointsAndPaddedTo24() {
        let controller = makePillController(skin: .hifi)
        controller.showHandsFree()
        for frame in controller.skin.controlFrames.values {
            #expect(frame.width == 11 && frame.height == 11)
            #expect(PillHit.target(for: frame).width == 24)
        }
        controller.hide()
    }
}

@MainActor
@Suite struct PillClickTests {
    private func click(_ controller: PillController, at local: CGPoint, upAt upLocal: CGPoint? = nil) {
        let number = controller.panel.windowNumber
        func event(_ type: NSEvent.EventType, _ p: CGPoint) -> NSEvent {
            NSEvent.mouseEvent(
                with: type, location: p, modifierFlags: [], timestamp: 0, windowNumber: number,
                context: nil, eventNumber: 0, clickCount: 1, pressure: 1
            )!
        }
        controller.host.mouseDown(with: event(.leftMouseDown, local))
        controller.host.mouseUp(with: event(.leftMouseUp, upLocal ?? local))
    }

    private func centre(_ controller: PillController, _ control: PillControl) -> CGPoint {
        let frame = controller.skin.controlFrames[control]!
        return CGPoint(x: frame.midX, y: frame.midY)
    }

    @Test(arguments: PillSkinKind.allCases) func clickingAControlFiresTheCallbackOnce(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        var fired: [PillControl] = []
        controller.onControl = { fired.append($0) }
        controller.showHandsFree()
        click(controller, at: centre(controller, .stop))
        click(controller, at: centre(controller, .cancel))
        #expect(fired == [.stop, .cancel])
        controller.hide()
    }

    @Test(arguments: PillSkinKind.allCases) func releasingOutsideCancelsTheClick(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        var fired: [PillControl] = []
        controller.onControl = { fired.append($0) }
        controller.showHandsFree()
        click(controller, at: centre(controller, .stop), upAt: CGPoint(x: 5, y: 5))
        click(controller, at: CGPoint(x: 5, y: 5))
        #expect(fired.isEmpty)
        controller.hide()
    }

    @Test(arguments: PillSkinKind.allCases) func nothingFiresWhenNotLocked(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        var fired: [PillControl] = []
        controller.onControl = { fired.append($0) }
        controller.showHandsFree()
        let stop = centre(controller, .stop)
        controller.showRecording()
        click(controller, at: stop)
        controller.showProcessing()
        click(controller, at: stop)
        #expect(fired.isEmpty)
        #expect(controller.host.hitTest(stop) == nil)
        controller.hide()
    }

    @Test(arguments: PillSkinKind.allCases) func hostOnlyAnswersHitTestsOverAControl(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        controller.showHandsFree()
        let stop = centre(controller, .stop)
        #expect(controller.host.hitTest(stop) === controller.host)
        #expect(controller.host.hitTest(CGPoint(x: 3, y: 3)) == nil)
        #expect(controller.host.acceptsFirstMouse(for: nil))
        controller.hide()
    }

    @Test(arguments: PillSkinKind.allCases) func panelSeesTheMouseOnlyOverAControlWhileLocked(kind: PillSkinKind) {
        let controller = makePillController(skin: kind)
        func screen(_ p: CGPoint) -> CGPoint {
            CGPoint(x: controller.panel.frame.minX + p.x, y: controller.panel.frame.minY + p.y)
        }
        #expect(controller.panel.ignoresMouseEvents)
        controller.showRecording()
        controller.updateInteractivity(pointer: screen(CGPoint(x: 184, y: 34)))
        #expect(controller.panel.ignoresMouseEvents)
        controller.showHandsFree()
        #expect(controller.panel.ignoresMouseEvents)
        controller.updateInteractivity(pointer: screen(centre(controller, .stop)))
        #expect(!controller.panel.ignoresMouseEvents)
        controller.updateInteractivity(pointer: screen(CGPoint(x: 184, y: 34)))
        #expect(controller.panel.ignoresMouseEvents)
        controller.updateInteractivity(pointer: screen(centre(controller, .cancel)))
        #expect(!controller.panel.ignoresMouseEvents)
        controller.showProcessing()
        #expect(controller.panel.ignoresMouseEvents)
        controller.hide()
    }

    @Test func panelNeverBecomesKeyOrMainEvenWhileLocked() {
        let controller = makePillController()
        controller.showHandsFree()
        let stop = centre(controller, .stop)
        let origin = controller.panel.frame.origin
        controller.updateInteractivity(pointer: CGPoint(x: origin.x + stop.x, y: origin.y + stop.y))
        #expect(!controller.panel.ignoresMouseEvents)
        #expect(!controller.panel.canBecomeKey && !controller.panel.canBecomeMain)
        #expect(controller.panel.styleMask.contains(.nonactivatingPanel))
        controller.hide()
    }
}
