import AppKit
import QuartzCore
import Testing
@testable import MouthtypeMac

@Suite struct MatrixPillLayoutTests {
    typealias L = MatrixPillLayout

    @Test(arguments: [PillScale.standard, .large])
    func theSquircleIs30PointsAndTwiceThatAtLarge(scale: PillScale) {
        let m = L.Metrics(scale)
        #expect(m.height == 30 * scale.factor)
        #expect(L.capsuleHeight(.hold, metrics: m) == 30 * scale.factor)
        #expect(L.capsuleHeight(.message(width: 200, height: 52), metrics: m) == 52)
        #expect(L.capsuleWidth(.hold, metrics: m) == 108 * scale.factor)
        #expect(L.capsuleWidth(.processing, metrics: m) == 108 * scale.factor)
        #expect(L.capsuleWidth(.locked, metrics: m) == 155 * scale.factor)
    }

    @Test(arguments: [PillScale.standard, .large])
    func theGridOf13x7DotsFitsTheMeterSlot(scale: PillScale) {
        let m = L.Metrics(scale)
        let midY: CGFloat = 15 * scale.factor
        var frames: [CGRect] = []
        for column in 0..<L.columns { for row in 0..<L.rows { frames.append(L.dotFrame(column: column, row: row, x: m.meterX, midY: midY, metrics: m)) } }
        #expect(frames.count == 91)
        #expect(frames.allSatisfy { $0.width == 2 * scale.factor && $0.height == 2 * scale.factor })
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        #expect(union.width == 38 * scale.factor && union.height == 20 * scale.factor)
        #expect(union.minX == m.meterX && union.maxX == m.meterX + m.meterWidth)
        #expect(union.midY == midY)
        #expect(union.minY >= 0 && union.maxY <= m.height)
        let first = L.dotFrame(column: 0, row: 0, x: m.meterX, midY: midY, metrics: m)
        let next = L.dotFrame(column: 1, row: 1, x: m.meterX, midY: midY, metrics: m)
        #expect(next.minX - first.minX == 3 * scale.factor && next.minY - first.minY == 3 * scale.factor)
    }

    @Test(arguments: [PillScale.standard, .large])
    func tenPlainBarsSitAt4PointPitch(scale: PillScale) {
        let m = L.Metrics(scale)
        let frames = (0..<L.barCount).map { L.barFrame(index: $0, halfRows: 2, x: m.meterX, midY: 15 * scale.factor, metrics: m) }
        #expect(frames.count == 10)
        #expect(frames.allSatisfy { $0.width == 2 * scale.factor })
        #expect(zip(frames, frames.dropFirst()).allSatisfy { $1.minX - $0.minX == 4 * scale.factor })
        let union = frames.reduce(CGRect.null) { $0.union($1) }
        #expect(union.width == L.meterWidth * scale.factor && union.maxX == m.meterX + m.meterWidth)
        #expect([0, 1, 2, 3, 4].map { L.barHeight(halfRows: $0, metrics: m) / scale.factor } == [2, 2, 8, 14, 20])
        #expect(frames.allSatisfy { $0.midY == 15 * scale.factor })
    }

    @Test func slotsAddUpToTheHeldAndLockedWidths() {
        let m = L.Metrics.standard
        #expect(m.indicatorCentre == 17 && m.meterX == 29 && m.labelX == 74 && m.textX == 29)
        #expect(m.heldWidth == 108)
        #expect(m.lockedWidth == 155)
        let capsule = CGRect(x: 100, y: 20, width: 155, height: 30)
        let frames = L.controlFrames(capsule: capsule)
        #expect(frames[.cancel] == CGRect(x: 207, y: 25, width: 20, height: 20))
        #expect(frames[.stop] == CGRect(x: 230, y: 25, width: 20, height: 20))
        #expect(capsule.maxX - frames[.stop]!.maxX == 5)
        #expect(frames[.stop]!.minX - frames[.cancel]!.maxX == 3)
        let large = L.controlFrames(capsule: CGRect(x: 0, y: 0, width: 310, height: 60), metrics: .large)
        #expect(large[.stop]!.width == 40 && 310 - large[.stop]!.maxX == 10 && large[.stop]!.minX - large[.cancel]!.maxX == 6)
    }

    @Test func messageGrowsFromTheHeldWidthAndWrapsAt150() {
        func block(_ text: String, detail: String? = nil, metrics: L.Metrics = .standard) -> ClassicPillLayout.MessageBlock {
            L.messageBlock(
                headline: text, detail: detail, headlineLineHeight: 17, detailLineHeight: 14, scale: 2, metrics: metrics
            ) { string, _ in CGFloat(string.count) * 7 * metrics.factor }
        }
        let short = block("Hi")
        #expect(short.width == 108 && short.height == 30 && short.lines.count == 1)
        let mid = block("Pasted okay now")
        #expect(mid.width == 29 + 105 + 12 && mid.lines.count == 1)
        let long = block("This message is much longer than the pill allows on one line")
        #expect(long.lines.count > 1 && long.height > 30)
        #expect(long.lines.allSatisfy { CGFloat($0.text.count) * 7 <= 150 })
        let two = block("Busy", detail: "Try again")
        #expect(two.lines.count == 2 && two.lines[1].isDetail && two.height > 30)
        let large = block("Hi", metrics: .large)
        #expect(large.width == 216 && large.height == 60)
    }

    @Test func levelsMapToHalfRowsOfTheDotMatrix() {
        #expect([0, 0.01, 0.0149].map { L.halfRows(fraction: $0) } == [0, 0, 0])
        #expect([0.015, 0.1, 0.2].map { L.halfRows(fraction: $0) } == [1, 1, 1])
        #expect([0.4, 0.5, 0.6].map { L.halfRows(fraction: $0) } == [2, 2, 2])
        #expect([0.7, 0.75, 0.8].map { L.halfRows(fraction: $0) } == [3, 3, 3])
        #expect([0.9, 1, 2].map { L.halfRows(fraction: $0) } == [4, 4, 4])
        #expect(L.halfRows(fraction: .nan) == 0 && L.halfRows(fraction: -1) == 0)
        #expect(L.litRows(halfRows: 0) == nil)
        #expect((0...4).map { L.litRows(halfRows: $0).map { $0.count } ?? 0 } == [0, 1, 3, 5, 7])
        #expect(L.litRows(halfRows: 1) == 3...3 && L.litRows(halfRows: 4) == 0...6)
        #expect(L.litRows(halfRows: 9) == 0...6)
    }

    @Test func tenBarLevelsSpreadAcrossThirteenColumns() {
        let ten: [Float] = [0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, 0.8, 0.9]
        let spread = L.columnFractions(from: ten, count: 13)
        #expect(spread.count == 13 && spread.first == 0 && abs(spread.last! - 0.9) < 0.0001)
        #expect(zip(spread, spread.dropFirst()).allSatisfy { $0 <= $1 })
        #expect(L.columnFractions(from: [0.5], count: 3) == [0.5, 0.5, 0.5])
        #expect(L.columnFractions(from: [], count: 2) == [0, 0])
        #expect(L.dotHalfRows(fractions: [Float](repeating: 1, count: 10)) == [Int](repeating: 4, count: 13))
        #expect(L.dotHalfRows(fractions: [Float](repeating: 0, count: 10)) == [Int](repeating: 0, count: 13))
        #expect(L.barHalfRows(fractions: [1, 0, 0.5]) == [4, 0, 2, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func theProcessingScannerBouncesAndStepsTheDots() {
        let atStart = L.processingFractions(time: 0, count: 13)
        let later = L.processingFractions(time: 0.45, count: 13)
        #expect(atStart.count == 13 && atStart != later)
        #expect(atStart.firstIndex { $0 > 0 } == 0 && later.lastIndex { $0 > 0 } == 12)
        #expect(L.processingFractions(time: 0, count: 13) == L.processingFractions(time: L.scannerPeriod, count: 13))
        #expect([0, 0.23, 0.45, 0.67, 0.89].map { L.processingDotsLit(time: $0) } == [0, 1, 2, 3, 0])
    }

    @Test func theSquircleHasSuperellipseCornersAndAStableShape() {
        let rect = CGRect(x: 10, y: 20, width: 108, height: 30)
        let path = L.squirclePath(rect, reference: 30)
        let box = path.boundingBox
        #expect(abs(box.minX - rect.minX) < 0.001 && abs(box.maxX - rect.maxX) < 0.001)
        #expect(abs(box.minY - rect.minY) < 0.001 && abs(box.maxY - rect.maxY) < 0.001)
        var count = 0
        path.applyWithBlock { _ in count += 1 }
        var other = 0
        L.squirclePath(CGRect(x: 0, y: 0, width: 310, height: 60), reference: 30).applyWithBlock { _ in other += 1 }
        #expect(count == other && count == 4 * 23 + 1)
        // The corner reaches 13.5 pt into each edge, and a superellipse bulges past a circle of that radius.
        let a = 0.34 * 1.32 * 30
        #expect(abs(a - 13.5) < 0.1)
        #expect(path.contains(CGPoint(x: rect.minX + a, y: rect.minY + 0.5)))
        #expect(!path.contains(CGPoint(x: rect.minX + 1, y: rect.minY + 1)))
        let circleInset = a * (1 - 1 / 2.0.squareRoot())
        #expect(path.contains(CGPoint(x: rect.minX + circleInset + 0.3, y: rect.minY + circleInset + 0.3)))
    }

    @Test func theLightWindowInsetsThreePointsAndEndsAfterTheClockWhenLocked() {
        let held = CGRect(x: 100, y: 20, width: 108, height: 30)
        let window = L.windowFrame(capsule: held, locked: false)
        #expect(window == CGRect(x: 103, y: 23, width: 102, height: 24))
        let locked = CGRect(x: 80, y: 20, width: 155, height: 30)
        let lockedWindow = L.windowFrame(capsule: locked, locked: true)
        #expect(lockedWindow.minX == 83 && lockedWindow.maxX == 80 + 74 + 26 + 4)
        #expect(lockedWindow.maxX < L.controlFrames(capsule: locked)[.cancel]!.minX)
    }

    @Test func lipsSpriteIsNineByNine() {
        #expect(LipsSprite.rows.count == 9 && LipsSprite.rows.allSatisfy { $0.count == 9 })
        #expect(LipsSprite.image(color: .white)?.width == 9)
    }
}

@MainActor
@Suite struct SquirclePillViewTests {
    private func view(_ kind: PillSkinKind, scale: PillScale = .standard, dark: Bool = true, reduceMotion: Bool = false) throws -> SquirclePillView {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
        let skin = try #require(try PillSkinFactory.make(kind, frame: frame, scale: scale) as? SquirclePillView)
        skin.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        skin.reduceMotionOverride = reduceMotion
        skin.appear(reduceMotion: reduceMotion)
        return skin
    }

    @Test func factoryAndControllerBuildTheRightViews() throws {
        #expect(try view(.matrix) is MatrixPillView)
        #expect(try view(.minimal) is MinimalPillView)
        #expect(makePillController(skin: .matrix).skin is MatrixPillView)
        #expect(makePillController(skin: .minimal).skin is MinimalPillView)
        #expect(PillSkinKind.matrix.pillHeight == 30 && PillSkinKind.minimal.pillHeight == 30 && PillSkinKind.glass.pillHeight == 28)
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal], [PillScale.standard, .large])
    func capsuleAndControlsFollowTheLayoutAtEverySize(kind: PillSkinKind, scale: PillScale) throws {
        let skin = try view(kind, scale: scale)
        let m = MatrixPillLayout.Metrics(scale)
        skin.showRecording(locked: false)
        #expect(skin.capsuleRect.size == CGSize(width: 108 * scale.factor, height: 30 * scale.factor))
        #expect(skin.controlFrames.isEmpty)
        skin.showRecording(locked: true)
        #expect(skin.capsuleRect.size == CGSize(width: 155 * scale.factor, height: 30 * scale.factor))
        let frames = skin.controlFrames
        #expect(frames == MatrixPillLayout.controlFrames(capsule: skin.capsuleRect, metrics: m))
        #expect(frames.values.allSatisfy { $0.width == 20 * scale.factor })
        #expect(skin.bounds.contains(skin.capsuleRect))
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal])
    func theClockShowsOnlyWhenLockedAndREConlyWhenHeld(kind: PillSkinKind) throws {
        let skin = try view(kind)
        skin.showRecording(locked: false)
        #expect(skin.showsRecLabel && !skin.showsClock)
        skin.showRecording(locked: true)
        #expect(!skin.showsRecLabel && skin.showsClock)
        skin.setElapsed(65)
        #expect(skin.clockString == "1:05")
        skin.beginProcessing()
        #expect(!skin.showsRecLabel && !skin.showsClock)
        skin.setElapsed(nil)
        #expect(skin.clockString == "1:05")
    }

    @Test func matrixLightsDotsAndMinimalLightsBarsFromTheSameLevels() throws {
        let matrix = try view(.matrix), minimal = try view(.minimal)
        let levels: [Float] = [0, 0.2, 0.5, 0.9, 1, 1, 0.9, 0.5, 0.2, 0]
        for skin in [matrix, minimal] { skin.showRecording(locked: false); skin.showFractions(levels) }
        #expect(matrix.litHalfRows.count == 13 && minimal.litHalfRows.count == 10)
        #expect(minimal.litHalfRows == MatrixPillLayout.barHalfRows(fractions: levels))
        #expect(matrix.litHalfRows == MatrixPillLayout.dotHalfRows(fractions: levels))
        #expect(matrix.litHalfRows[6] == 4 && matrix.litHalfRows[0] == 0 && minimal.litHalfRows[4] == 4)
        matrix.showFractions(levels)
        #expect(matrix.litHalfRows == MatrixPillLayout.dotHalfRows(fractions: levels))
        matrix.beginProcessing()
        matrix.updateProcessing(time: 0.2)
        #expect(matrix.litHalfRows != MatrixPillLayout.dotHalfRows(fractions: levels))
    }

    @Test func matrixFollowsTheAppearanceWithAWindowOnlyWhenLight() throws {
        #expect(try view(.matrix, dark: true).usesWindow == false)
        #expect(try view(.matrix, dark: false).usesWindow == true)
        #expect(try view(.minimal, dark: false).usesWindow == false)
        let dark = SquirclePalette.resolve(.matrix, dark: true), light = SquirclePalette.resolve(.matrix, dark: false)
        #expect(dark.ink == NSColor(hex: 0xFFB327) && dark.rec == NSColor(hex: 0xFF4A3C) && dark.ghostAlpha == 0.11)
        #expect(dark.glow == NSColor(hex: 0xFF9A10) && dark.bodyTop == NSColor(hex: 0x252528) && dark.bodyBottom == NSColor(hex: 0x19191B))
        #expect(light.ink == NSColor(hex: 0x1D2815) && light.window?.top == NSColor(hex: 0xBFCAA6) && light.glow == nil)
    }

    @Test func minimalPaletteFollowsTheSystemAppearance() {
        let dark = SquirclePalette.resolve(.minimal, dark: true), light = SquirclePalette.resolve(.minimal, dark: false)
        #expect(dark.ink == NSColor(hex: 0xF4F3E8) && dark.rec == NSColor(hex: 0xFF453A))
        #expect(dark.bodyTop == NSColor(hex: 0x252528) && dark.window == nil)
        #expect(light.ink == NSColor(hex: 0x1D1D1F) && light.rec == NSColor(hex: 0xE0281C) && light.error == NSColor(hex: 0xD70015))
        #expect(light.bodyTop == NSColor(hex: 0xFBFBFC) && light.bodyBottom == NSColor(hex: 0xE6E6EA) && light.window == nil)
        #expect(light.hairline.alphaComponent == 0.16)
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal])
    func theRecLampBreathesOnATwoSecondCycleUnlessReduceMotionIsOn(kind: PillSkinKind) throws {
        let moving = try view(kind, reduceMotion: false)
        moving.showRecording(locked: false)
        let animation = try #require(moving.lampAnimation as? CABasicAnimation)
        #expect(moving.lampMotion == .breathing)
        #expect(animation.keyPath == "opacity" && animation.autoreverses && animation.repeatCount == .infinity)
        #expect(animation.duration * 2 == 2)
        #expect(animation.fromValue as? Double == 1 && animation.toValue as? Double == 0.78)

        let still = try view(kind, reduceMotion: true)
        still.showRecording(locked: false)
        #expect(still.lampMotion == .steady && still.lampAnimation == nil && still.lampOpacity == 1)
        still.showRecording(locked: true)
        still.beginProcessing()
        #expect(still.lampMotion == .steady && still.lampAnimation == nil)
        still.showMessage(PillMessage("Failed", isError: true), overRecording: false)
        #expect(still.lampMotion == .steady && still.lampAnimation == nil)
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal])
    func theLampStopsBreathingWhenTheStateChanges(kind: PillSkinKind) throws {
        let skin = try view(kind)
        skin.showRecording(locked: false)
        #expect(skin.lampMotion == .breathing)
        skin.showRecording(locked: true)
        #expect(skin.lampMotion == .steady && skin.lampAnimation == nil)
        skin.beginProcessing()
        #expect(skin.lampMotion == .pulsing && skin.lampAnimation != nil)
        skin.showMessage(PillMessage("Pasted"), overRecording: false)
        #expect(skin.lampMotion == .steady && skin.lampAnimation == nil)
        skin.showMessage(PillMessage("Paste failed", isError: true), overRecording: false)
        #expect(skin.lampMotion == .flashing)
        let flash = try #require(skin.lampAnimation as? CAKeyframeAnimation)
        #expect(flash.duration == 1.1 && flash.repeatCount == 0)
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal], [PillScale.standard, .large])
    func messagesErrorsAndDetailsLayOut(kind: PillSkinKind, scale: PillScale) throws {
        let skin = try view(kind, scale: scale)
        skin.showMessage(PillMessage("Pasted"), overRecording: false)
        #expect(skin.messageLines.count == 1 && skin.messageSize.height == 30 * scale.factor)
        #expect(skin.messageSize.width >= 108 * scale.factor && skin.capsuleRect.width == skin.messageSize.width)
        skin.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        #expect(skin.messageLines.map(\.isDetail) == [false, true])
        #expect(skin.messageSize.height > 30 * scale.factor && skin.capsuleRect.height == skin.messageSize.height)
        skin.showMessage(PillMessage("Paste failed", isError: true), overRecording: false)
        #expect(skin.messageLines.count == 1 && !skin.isLocked && skin.controlFrames.isEmpty)
        skin.showMessage(PillMessage("A very long notice that has to wrap onto several lines of the pill"), overRecording: false)
        #expect(skin.messageLines.count > 1)
        #expect(skin.messageScrollDistance == 0)
    }

    @Test func aNoticeOverALockedRecordingKeepsTheLockWithoutControls() throws {
        let skin = try view(.matrix)
        skin.showRecording(locked: true)
        skin.showMessage(PillMessage("1 minute left"), overRecording: true)
        #expect(skin.isLocked && skin.controlFrames.isEmpty)
        skin.showRecording(locked: true)
        #expect(skin.controlFrames.count == 2)
    }

    static let longError = (
        "The transcription engine stopped before it finished because the model could not be loaded from disk. "
            + "Check that the model folder still exists and has enough free space, then try again in a moment. "
            + "If it keeps failing, quit Mouthtype from the menu bar and open it again to reload everything."
    )

    @Test(arguments: [PillSkinKind.matrix, .minimal], [PillScale.standard, .large])
    func aLongMessageStaysInThePanelAndScrollsUntilAllOfItHasBeenSeen(kind: PillSkinKind, scale: PillScale) throws {
        #expect(Self.longError.count >= 280)
        let skin = try view(kind, scale: scale)
        skin.showMessage(PillMessage("Transcription failed", detail: Self.longError, isError: true), overRecording: false)
        let cap = PillGeometry.maxPillSize.height * scale.factor
        #expect(skin.messageSize.height == cap && skin.capsuleRect.height == cap)
        #expect(skin.capsuleRect.minY >= PillGeometry.verticalMargin)
        #expect(skin.capsuleRect.maxY <= skin.bounds.height - PillGeometry.verticalMargin)
        let distance = skin.messageScrollDistance
        #expect(distance > 0)

        // Every line is wholly inside the viewport at some point of the scroll, and the viewport stays inside the capsule.
        var seen = Set<Int>()
        for offset in stride(from: 0, through: -distance, by: -1) {
            skin.setMessageOffset(offset)
            let viewport = skin.messageViewport
            #expect(viewport.minY >= 0 && viewport.maxY <= skin.capsuleRect.height)
            for (index, frame) in skin.messageLineFrames.enumerated() where viewport.insetBy(dx: -1, dy: -1).contains(frame) {
                seen.insert(index)
            }
        }
        #expect(seen == Set(skin.messageLines.indices))

        // The first line starts at the top of the viewport, and the text is never truncated.
        skin.setMessageOffset(0)
        // The text box sits within a point of the viewport's top edge; the line's glyphs sit inside it.
        #expect(skin.messageLineFrames[0].maxY <= skin.messageViewport.maxY + 1.5)
        let shown = skin.messageLines.filter(\.isDetail).map(\.text).joined(separator: " ")
        #expect(shown == Self.longError && !shown.contains("\u{2026}"))
    }

    @Test(arguments: [PillSkinKind.matrix, .minimal])
    func aMessageThatFitsDoesNotScroll(kind: PillSkinKind) throws {
        let skin = try view(kind)
        skin.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        #expect(skin.messageScrollDistance == 0)
        let before = skin.messageLineFrames
        skin.setMessageOffset(-20)
        #expect(skin.messageLineFrames == before)
        #expect(skin.messageViewport == CGRect(x: 0, y: 0, width: skin.capsuleRect.width, height: skin.capsuleRect.height))
    }
}
