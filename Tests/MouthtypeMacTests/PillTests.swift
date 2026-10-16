import AppKit
import Testing
@testable import MouthtypeMac

@Suite struct BarModelTests {
    private let dt = 1.0 / 60

    /// Steps the model for `seconds` with a level given as a function of time, returning every frame's fractions.
    private func run(
        _ model: inout BarModel, seconds: Double, from start: Double = 0, level: (Double) -> Float
    ) -> [[Float]] {
        var frames: [[Float]] = []
        for i in 0..<Int(seconds / dt) {
            frames.append(model.step(reading: LevelReading(db: level(start + Double(i) * dt)), dt: dt))
        }
        return frames
    }

    private func steady(_ model: inout BarModel, db: Float, seconds: Double) -> [Float] {
        run(&model, seconds: seconds) { _ in db }.last ?? []
    }

    /// Speech at `rms` dBFS overall power: the short-term level swings `depth` dB at `hz` syllables a second, from a
    /// peak down to the gap between syllables.
    private func speech(rms: Float, depth: Float = 24, hz: Double = 4) -> (Double) -> Float {
        var sum = 0.0
        let n = 1_000
        for i in 0..<n { sum += pow(10, -Double(depth) * (0.5 + 0.5 * cos(2 * .pi * Double(i) / Double(n))) / 10) }
        let peak = rms - Float(10 * log10(sum / Double(n)))
        return { t in peak - depth * Float(0.5 - 0.5 * cos(2 * .pi * hz * t)) }
    }

    private func lit(_ fractions: [Float]) -> [Int] {
        BarModel.litSegments(fractions, segments: BarModel.segmentRows)
    }

    /// The tallest column in each frame.
    private func tops(_ frames: [[Float]]) -> [Float] { frames.map { $0.max() ?? 0 } }

    @Test func silenceShowsOnlyTheBaselineSegment() {
        var model = BarModel()
        let fractions = steady(&model, db: -120, seconds: 1)
        #expect(fractions.count == 10)
        #expect(fractions.allSatisfy { $0 == 0 })
        #expect(lit(fractions) == [Int](repeating: 1, count: 10))
    }

    @Test func minusFiftyFiveDecibelsIsRestingDots() {
        var model = BarModel()
        let frames = run(&model, seconds: 5) { _ in -55 }
        #expect(frames.allSatisfy { $0.allSatisfy { $0 == 0 } })
        // Room noise a little above that, as measured at the high end (-47), also ends at rest once the floor follows it.
        var noisy = BarModel()
        _ = run(&noisy, seconds: 20) { _ in -50 }
        #expect(steady(&noisy, db: -50, seconds: 2).allSatisfy { $0 == 0 })
    }

    @Test func fractionIsLinearInDecibelsThenKneesBelowOne() {
        let f = { (db: Float) in BarModel.fraction(db: db, floor: -55, ceiling: -12) }
        #expect(f(-55) == 0 && f(-70) == 0 && f(-.infinity) == 0 && f(.nan) == 0)
        #expect(abs(f(-40) - 0.35) < 0.01)
        #expect(abs(f(-33.5) - 0.5) < 0.01)
        #expect(abs(f(-20) - 0.81) < 0.02)
        // Linear up to the knee, then compressing but still rising.
        #expect(abs(f(-55 + 0.7 * 43) - 0.7) < 1e-4)
        var last: Float = 0
        for step in -70...10 {
            let v = f(Float(step))
            #expect(v >= last && v <= 1)
            last = v
        }
        #expect(f(-12) > 0.9 && f(-12) < 0.97)
        #expect(f(-6) > f(-12) && f(-6) < 1)
        #expect(f(10) <= 1)
    }

    @Test func ordinarySpeechMovesTheTallestBarsBetweenAThirdAndFourFifths() {
        var model = BarModel()
        let level = speech(rms: -32)
        _ = run(&model, seconds: 12, level: level)
        let frames = run(&model, seconds: 4, from: 12, level: level)
        let peaks = tops(frames)
        let high = peaks.max() ?? 0, low = peaks.min() ?? 0
        #expect(high >= 0.35 && high <= 0.8, "peak \(high)")
        #expect(low < 0.4 * high, "trough \(low) against peak \(high)")
        // Steady speech should spend its time inside the band, not at the ceiling.
        #expect(peaks.filter { $0 > 0.8 }.isEmpty)
    }

    @Test func theMeterFallsBetweenWords() {
        var model = BarModel()
        _ = steady(&model, db: -28, seconds: 1)
        let top = model.step(reading: LevelReading(db: -28), dt: dt)[4]
        var after100 = [Float](), after300 = [Float]()
        for i in 1...18 {
            let f = model.step(reading: LevelReading(db: -62), dt: dt)
            if i == 6 { after100 = f }
            if i == 18 { after300 = f }
        }
        #expect(after100[4] < 0.5 * top, "100 ms gap")
        #expect(after300.max()! < 0.12 * top, "300 ms gap")
    }

    @Test func aLoudInputReachesNearFullWithoutFlatToppingForLong() {
        var model = BarModel()
        // Loud speech: -10 dBFS short-term, swinging 6 dB at 4 Hz.
        let level: (Double) -> Float = { t in -10 + 8 * Float(sin(2 * .pi * 4 * t)) }
        let frames = run(&model, seconds: 10, level: level)
        let peaks = tops(Array(frames.suffix(240)))
        #expect(peaks.max()! > 0.9)
        let pinned = peaks.filter { $0 > 0.995 }.count
        #expect(Double(pinned) / Double(peaks.count) < 0.1, "\(pinned) of \(peaks.count) frames flat at the top")
        #expect(peaks.max()! - peaks.min()! > 0.1, "still moving")
    }

    @Test func aQuietTalkerGetsMovementWithinAFewSeconds() {
        var model = BarModel()
        let level = speech(rms: -45)
        let early = tops(run(&model, seconds: 1, level: level))
        _ = run(&model, seconds: 5, from: 1, level: level)
        let settled = tops(run(&model, seconds: 3, from: 6, level: level))
        #expect(model.adapter.ceilingDb < -18, "ceiling \(model.adapter.ceilingDb)")
        #expect(settled.max()! > 0.35, "settled peak \(settled.max()!)")
        #expect(settled.max()! > early.max()!)
        #expect(settled.min()! < 0.4 * settled.max()!)
    }

    @Test func silenceNeverRaisesTheGain() {
        var model = BarModel()
        let before = model.adapter.ceilingDb
        _ = run(&model, seconds: 30) { _ in -58 }
        #expect(model.adapter.ceilingDb == before)
        _ = run(&model, seconds: 30) { _ in -48 }
        #expect(model.adapter.ceilingDb == before)
        // And speech after the silence is where it was.
        var fresh = BarModel()
        let a = tops(run(&model, seconds: 3, level: speech(rms: -32)))
        let b = tops(run(&fresh, seconds: 3, level: speech(rms: -32)))
        #expect(abs(a.max()! - b.max()!) < 0.1)
    }

    @Test func theRangeStaysInsideItsBounds() {
        var adapter = MeterAdapter()
        for (db, seconds) in [(Float(-120), 30.0), (-20, 5), (0, 60), (-45, 60), (-70, 60), (-40, 60), (.nan, 1)] {
            for _ in 0..<Int(seconds * 60) {
                adapter.update(db: db.isFinite ? db : -30, dt: 1.0 / 60)
                #expect(MeterAdapter.floorLimits.contains(adapter.floorDb))
                #expect(adapter.ceilingDb >= adapter.floorDb + MeterAdapter.minimumSpan)
                #expect(adapter.ceilingDb <= MeterAdapter.ceilingLimits.upperBound + 0.001)
            }
        }
    }

    @Test func theRangeDoesNotPumpOnASingleShoutOrAPause() {
        var model = BarModel()
        _ = run(&model, seconds: 15, level: speech(rms: -32))
        let before = model.adapter.ceilingDb
        // A one-second shout.
        _ = run(&model, seconds: 1) { _ in -8 }
        #expect(abs(model.adapter.ceilingDb - before) < 6)
        // Then a long quiet gap: nothing moves.
        let afterShout = model.adapter.ceilingDb
        _ = run(&model, seconds: 10) { _ in -62 }
        #expect(model.adapter.ceilingDb == afterShout)
    }

    @Test func fractionsNeverLeaveTheRange() {
        var model = BarModel()
        for db: Float in [-500, -120, -55, -30, 0, 40, .nan, .infinity, -.infinity, -20, -90] {
            for dt in [0.0, 0.001, 0.016, 5, .nan] {
                let fractions = model.step(reading: LevelReading(db: db, low: db + 30, mid: .nan, high: -.infinity), dt: dt)
                #expect(fractions.count == 10)
                #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
                #expect(lit(fractions).allSatisfy { (1...BarModel.segmentRows).contains($0) })
            }
        }
    }

    @Test func theMiddleColumnsAreTallestAndTheEndsLower() {
        var model = BarModel()
        let counts = lit(steady(&model, db: -14, seconds: 1))
        #expect(counts[4] == BarModel.segmentRows && counts[5] == BarModel.segmentRows)
        #expect(counts[0] < counts[4])
        #expect(counts[9] < counts[5])
        #expect(counts[0] > 1)
    }

    @Test func outerColumnsLagTheMiddleSoSpeechRipplesOutward() {
        var model = BarModel()
        _ = steady(&model, db: -62, seconds: 1)
        var first: [Float] = []
        var reachedMiddle = -1, reachedEnd = -1
        for i in 0..<30 {
            first = model.step(reading: LevelReading(db: -25), dt: dt)
            if reachedMiddle < 0, first[4] > 0.15 { reachedMiddle = i }
            if reachedEnd < 0, first[0] > 0.15 { reachedEnd = i }
        }
        #expect(reachedMiddle >= 0 && reachedEnd > reachedMiddle)
    }

    @Test func columnsDifferWhenTheBandsDo() {
        var vowel = BarModel(), hiss = BarModel()
        var v: [Float] = [], h: [Float] = []
        for _ in 0..<60 {
            v = vowel.step(reading: LevelReading(db: -26, low: -28, mid: -33, high: -42), dt: dt)
            h = hiss.step(reading: LevelReading(db: -26, low: -42, mid: -34, high: -27), dt: dt)
        }
        #expect(v[1] / BarModel.weights[1] > v[8] / BarModel.weights[8])
        #expect(h[8] / BarModel.weights[8] > h[1] / BarModel.weights[1])
    }

    @Test func releaseReachesTheBaseline() {
        var model = BarModel()
        _ = steady(&model, db: -14, seconds: 1)
        let end = steady(&model, db: -120, seconds: 2)
        #expect(lit(end) == [Int](repeating: 1, count: 10))
    }

    @Test func quantisationGivesWholeSegmentsAcrossTheRange() {
        let rows = BarModel.segmentRows
        #expect(BarModel.litSegments([0, 0.001, 0.2, 0.21, 0.5, 0.99, 1], segments: rows) == [1, 1, 1, 2, 3, 5, 5])
        #expect(BarModel.litSegments([-3, 7, .nan, .infinity], segments: rows) == [1, rows, 1, 1])
        var last = 0
        for step in 0...100 {
            let count = BarModel.litSegments([Float(step) / 100], segments: rows)[0]
            #expect(count >= last && (1...rows).contains(count))
            last = count
        }
    }

    @Test func weightsPeakInTheMiddleAndFallToTheEnds() {
        let w = BarModel.weights
        #expect(w.count == 10)
        #expect(w[4] == 1 && w[5] == 1)
        #expect(w[0] < w[2] && w[2] < w[4])
        #expect(w[9] < w[7] && w[7] < w[5])
    }

    @Test func processingRunTravelsBackAndForthInsideTheRow() {
        var seen = Set<Int>()
        for t in stride(from: 0.0, to: 3, by: 0.05) {
            let run = BarModel.processingColumns(time: t, columns: 10)
            #expect(run.lowerBound >= 0 && run.upperBound <= 9 && run.count <= 3)
            seen.insert(run.lowerBound)
        }
        #expect(seen.contains(0) && seen.contains(8))
        #expect(BarModel.processingColumns(time: 0, columns: 10) != BarModel.processingColumns(time: 0.5, columns: 10))
        #expect(BarModel.processingColumns(time: .nan, columns: 10) == 0...1)
    }
}

@Suite struct PillPlacementTests {
    private let left = PillPlacement.Screen(
        frame: CGRect(x: 0, y: 0, width: 1600, height: 1000), visibleFrame: CGRect(x: 0, y: 80, width: 1600, height: 895)
    )
    private let right = PillPlacement.Screen(
        frame: CGRect(x: 1600, y: -200, width: 1920, height: 1080), visibleFrame: CGRect(x: 1600, y: -200, width: 1920, height: 1055)
    )
    private let size = CGSize(width: 360, height: 40)

    @Test func centresAtTheBottomOfThePointersScreen() {
        let onLeft = PillPlacement.origin(pointer: CGPoint(x: 100, y: 500), screens: [left, right], panelSize: size, pillPadding: 6)
        #expect(onLeft == CGPoint(x: 800 - 180, y: 80 + 12 - 6))
        let onRight = PillPlacement.origin(pointer: CGPoint(x: 2000, y: 0), screens: [left, right], panelSize: size, pillPadding: 6)
        #expect(onRight == CGPoint(x: 2560 - 180, y: -200 + 12 - 6))
    }

    @Test func pointerOutsideEveryScreenFallsBackToTheFirst() {
        let origin = PillPlacement.origin(pointer: CGPoint(x: -500, y: 5000), screens: [left, right], panelSize: size, pillPadding: 6)
        #expect(origin == CGPoint(x: 800 - 180, y: 86))
    }

    @Test func noScreensGivesNoOrigin() {
        #expect(PillPlacement.origin(pointer: .zero, screens: [], panelSize: size, pillPadding: 6) == nil)
    }
}

@MainActor
func makePillController(skin: PillSkinKind? = nil, level: @escaping @MainActor () -> LevelReading = { .silence }) -> PillController {
    _ = NSApplication.shared
    let defaults = UserDefaults(suiteName: "pill-tests-\(UUID().uuidString)")!
    if let skin { PillSkinPreference.set(skin, in: defaults) }
    return PillController(level: level, defaults: defaults)
}

@MainActor
@Suite struct PillPanelTests {
    @Test func panelIsConfiguredToNeverTakeFocus() {
        let controller = makePillController()
        let panel = controller.panel
        #expect(panel.styleMask.contains(.borderless))
        #expect(panel.styleMask.contains(.nonactivatingPanel))
        #expect(panel.level == .statusBar)
        #expect(panel.collectionBehavior == [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary])
        #expect(panel.ignoresMouseEvents)
        #expect(panel.canBecomeKey == false)
        #expect(panel.canBecomeMain == false)
        #expect(panel.hasShadow == false)
        #expect(panel.isOpaque == false)
        #expect(panel.isVisible == false)
    }

    @Test func pillIsTheDrawnSizeAndTheSkinAgrees() throws {
        let assets = try PillAssets.loadHiFi()
        #expect(HiFiPillView.artSize == CGSize(width: assets.layout.size.w, height: assets.layout.size.h))
        let view = HiFiPillView(frame: NSRect(origin: .zero, size: PillController.panelSize), assets: assets)
        #expect(view.pillSize == CGSize(width: 146 * view.artScale, height: 32 * view.artScale))
        #expect(PillController.panelSize.width >= view.pillSize.width)
        #expect(PillController.panelSize.height >= view.pillSize.height + 2 * PillController.pillPadding)
        #expect(view.artScale.rounded() == view.artScale)
        #expect(assets.layout.meter.columns == BarModel.barCount)
        #expect(assets.layout.meter.segmentsPerColumn == BarModel.segmentRows)
    }

    @Test func handsFreeLocksTheViewAndTheTimerSurvivesANotice() {
        let controller = makePillController()
        #expect(!controller.skin.isLocked)
        controller.showHandsFree()
        #expect(controller.state == .handsFree && controller.skin.isLocked)
        controller.showRecording()
        #expect(controller.state == .recording && !controller.skin.isLocked)
        controller.showHandsFree()
        controller.showProcessing()
        #expect(!controller.skin.isLocked)
        controller.hide()
    }

    @Test func longMessagesScrollAndShortOnesStayPut() {
        let controller = makePillController(skin: .hifi)
        controller.showMessage("Too short", duration: 5)
        #expect(controller.skin.messageScrollDistance == 0)
        controller.showMessage("Secure field, not pasted. Copied to the clipboard instead.", duration: 5)
        #expect(controller.skin.messageScrollDistance > 0)
        controller.hide()
    }

    @Test func noticeOverAHandsFreeRecordingComesBackToIt() async {
        let controller = makePillController()
        controller.showHandsFreeNotice("1 min left", duration: 0.05)
        #expect(controller.state == .hidden)
        controller.showHandsFree()
        controller.showHandsFreeNotice("1 min left", duration: 0.05)
        #expect(controller.state == .message(PillMessage("1 min left")))
        // Poll rather than sleep once: other main-actor tests can hold the actor past a fixed delay.
        for _ in 0..<40 where controller.state != .handsFree { try? await Task.sleep(for: .milliseconds(50)) }
        #expect(controller.state == .handsFree)
        controller.hide()
    }
}
