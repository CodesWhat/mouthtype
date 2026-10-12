import AppKit
import Testing
@testable import MouthtypeMac

@Suite struct BarModelTests {
    private func run(_ model: inout BarModel, level: Float, seconds: Double, dt: Double = 1.0 / 60) -> [Float] {
        var fractions: [Float] = []
        for _ in 0..<Int(seconds / dt) { fractions = model.step(level: level, dt: dt) }
        return fractions
    }

    private func lit(_ fractions: [Float]) -> [Int] {
        BarModel.litSegments(fractions, segments: BarModel.segmentRows)
    }

    @Test func silenceShowsOnlyTheBaselineSegment() {
        var model = BarModel()
        let fractions = run(&model, level: 0, seconds: 1)
        #expect(fractions.count == 10)
        #expect(fractions.allSatisfy { $0 == 0 })
        #expect(lit(fractions) == [Int](repeating: 1, count: 10))
    }

    @Test func fullLevelFillsTheMiddleColumnsAndLessAtTheEnds() {
        var model = BarModel()
        let counts = lit(run(&model, level: 1, seconds: 1))
        #expect(counts[4] == BarModel.segmentRows && counts[5] == BarModel.segmentRows)
        #expect(counts[0] < counts[4])
        #expect(counts[9] < counts[5])
        #expect(counts[0] > 1)
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

    @Test func fractionsNeverLeaveTheRange() {
        var model = BarModel()
        for level: Float in [-5, 0, 0.3, 1, 7, .nan, .infinity, -.infinity, 1, 0] {
            for dt in [0.0, 0.001, 0.016, 5, .nan] {
                let fractions = model.step(level: level, dt: dt)
                #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
                #expect(lit(fractions).allSatisfy { (1...BarModel.segmentRows).contains($0) })
            }
        }
    }

    @Test func releaseDecaysSlowerThanAttackAndReachesTheBaseline() {
        var model = BarModel()
        let attack = run(&model, level: 1, seconds: 0.1)
        let loud = run(&model, level: 1, seconds: 1)
        #expect(attack[4] > 0.9)

        let early = run(&model, level: 0, seconds: 0.1)
        let later = run(&model, level: 0, seconds: 0.2)
        #expect(early[4] < loud[4])
        #expect(early[4] > later[4])
        #expect(early[4] > 0.05)
        let end = run(&model, level: 0, seconds: 2)
        #expect(lit(end) == [Int](repeating: 1, count: 10))
    }

    @Test func outerColumnsLagTheMiddle() {
        var model = BarModel()
        var first: [Float] = []
        for _ in 0..<3 { first = model.step(level: 1, dt: 1.0 / 60) }
        #expect(first[4] > first[0])
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
func makePillController(skin: PillSkinKind? = nil, level: @escaping @MainActor () -> Float = { 0 }) -> PillController {
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
        #expect(HiFiPillView.pillSize == CGSize(width: 146 * HiFiPillView.artScale, height: 32 * HiFiPillView.artScale))
        #expect(PillController.panelSize.width >= HiFiPillView.pillSize.width)
        #expect(PillController.panelSize.height >= HiFiPillView.pillSize.height + 2 * PillController.pillPadding)
        #expect(HiFiPillView.artScale.rounded() == HiFiPillView.artScale)
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
