import AppKit
import Testing
@testable import MouthtypeMac

@Suite struct BarModelTests {
    private func run(_ model: inout BarModel, level: Float, seconds: Double, dt: Double = 1.0 / 60) -> [CGFloat] {
        var heights: [CGFloat] = []
        for _ in 0..<Int(seconds / dt) { heights = model.step(level: level, dt: dt) }
        return heights
    }

    @Test func silenceIsTenDots() {
        var model = BarModel()
        let heights = run(&model, level: 0, seconds: 1)
        #expect(heights.count == 10)
        #expect(heights.allSatisfy { $0 == BarModel.minHeight })
    }

    @Test func fullLevelReachesTheMaxInTheMiddleAndLessAtTheEnds() {
        var model = BarModel()
        let heights = run(&model, level: 1, seconds: 1)
        #expect(abs(heights[4] - BarModel.maxHeight) < 0.01)
        #expect(abs(heights[5] - BarModel.maxHeight) < 0.01)
        #expect(heights[0] < heights[4] - 2)
        #expect(heights[9] < heights[5] - 2)
        #expect(heights[0] > BarModel.minHeight)
    }

    @Test func heightsNeverLeaveTheRange() {
        var model = BarModel()
        for level: Float in [-5, 0, 0.3, 1, 7, .nan, .infinity, -.infinity, 1, 0] {
            for dt in [0.0, 0.001, 0.016, 5, .nan] {
                let heights = model.step(level: level, dt: dt)
                #expect(heights.allSatisfy { $0 >= BarModel.minHeight && $0 <= BarModel.maxHeight })
            }
        }
    }

    @Test func releaseDecaysSlowerThanAttackAndReachesDots() {
        var model = BarModel()
        let attack = run(&model, level: 1, seconds: 0.1)
        let loud = run(&model, level: 1, seconds: 1)
        #expect(attack[4] > BarModel.maxHeight - 1.5)

        let early = run(&model, level: 0, seconds: 0.1)
        let later = run(&model, level: 0, seconds: 0.2)
        #expect(early[4] < loud[4])
        #expect(early[4] > later[4])
        #expect(early[4] > BarModel.minHeight + 1)
        let end = run(&model, level: 0, seconds: 2)
        #expect(end.allSatisfy { $0 == BarModel.minHeight })
    }

    @Test func outerBarsLagTheMiddle() {
        var model = BarModel()
        var first: [CGFloat] = []
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

    @Test func rippleStaysCalmAndInRange() {
        for t in stride(from: 0.0, to: 5, by: 0.05) {
            let heights = BarModel.ripple(time: t)
            #expect(heights.count == 10)
            #expect(heights.allSatisfy { $0 >= BarModel.minHeight && $0 <= BarModel.minHeight + 4 })
        }
        #expect(BarModel.ripple(time: 0) != BarModel.ripple(time: 0.35))
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
@Suite struct PillPanelTests {
    @Test func panelIsConfiguredToNeverTakeFocus() {
        _ = NSApplication.shared
        let controller = PillController(level: { 0 })
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

    @Test func messageWidthFitsTextAndNeverExceedsTheCap() {
        #expect(PillView.pillWidth(forMessage: "x", max: 332) == PillView.pillSize.width)
        let short = PillView.pillWidth(forMessage: "Secure field, not pasted", max: 332)
        #expect(short > PillView.pillSize.width && short <= 332)
        #expect(PillView.pillWidth(forMessage: String(repeating: "wide ", count: 60), max: 332) == 332)
    }
}
