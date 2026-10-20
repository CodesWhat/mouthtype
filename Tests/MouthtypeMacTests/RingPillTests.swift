import AppKit
import QuartzCore
import Testing
@testable import MouthtypeMac

@Suite struct RingPillLayoutTests {
    typealias L = RingPillLayout

    @Test(arguments: [PillScale.standard, .large])
    func largeIsExactlyTwiceStandard(scale: PillScale) {
        let m = L.Metrics(scale)
        let k = scale.factor
        #expect(m.diameter == 40 * k && m.innerRadius == 11 * k && m.ringRadius == 12 * k)
        #expect(m.maxSpokeLength == 7 * k && m.spokeWidth == 1.5 * k && m.dotRadius == 2.75 * k)
        #expect(L.capsuleWidth(.hold, metrics: m) == m.diameter && L.capsuleHeight(.hold, metrics: m) == m.diameter)
        #expect(L.capsuleWidth(.processing, metrics: m) == m.diameter)
        #expect(L.capsuleWidth(.locked, metrics: m) == m.diameter + 2 * (18 + 5 + 4) * k)
    }

    @Test func aMessageNeverShrinksTheBodyBelowTheCircle() {
        let m = L.Metrics.standard
        #expect(L.capsuleWidth(.message(width: 20, height: 20), metrics: m) == 40)
        #expect(L.capsuleHeight(.message(width: 20, height: 20), metrics: m) == 40)
        #expect(L.capsuleWidth(.message(width: 180, height: 62), metrics: m) == 180)
        #expect(L.capsuleHeight(.message(width: 180, height: 62), metrics: m) == 62)
    }

    @Test func spokesAreEvenlySpacedFromTwelveOClock() {
        #expect(L.spokeAngle(index: 0) == 0)
        #expect(abs(L.spokeAngle(index: L.spokeCount / 4) - .pi / 2) < 1e-9)
        #expect(abs(L.spokeAngle(index: L.spokeCount / 2) - .pi) < 1e-9)
        #expect(L.spokeAngle(index: 3, count: 0) == 0)
        #expect(L.spokeCount % 4 == 0 && (24...32).contains(L.spokeCount))
    }

    @Test func foldedPositionIsZeroAtTheTopAndBottomAndOneAtTheSides() {
        #expect(L.foldedPosition(angle: 0) == 0)
        #expect(abs(L.foldedPosition(angle: .pi / 2) - 1) < 1e-9)
        #expect(abs(L.foldedPosition(angle: .pi)) < 1e-9)
        #expect(abs(L.foldedPosition(angle: 3 * .pi / 2) - 1) < 1e-9)
        #expect(abs(L.foldedPosition(angle: .pi / 4) - 0.5) < 1e-9)
        #expect(L.foldedPosition(angle: .nan) == 0)
        #expect(abs(L.foldedPosition(angle: -.pi / 2) - 1) < 1e-9)
    }

    @Test func foldingAveragesEachBarWithItsMirror() {
        let ten: [Float] = [0.0, 0.1, 0.2, 0.3, 0.4, 0.6, 0.8, 1.0, 0.5, 0.2]
        let folded = L.folded(ten)
        #expect(folded.count == 5)
        #expect(abs(folded[0] - 0.5) < 1e-6)   // 0.4 and 0.6
        #expect(abs(folded[1] - 0.55) < 1e-6)  // 0.3 and 0.8
        #expect(abs(folded[4] - 0.1) < 1e-6)   // 0.0 and 0.2
        #expect(L.folded([0.2, 0.4, 0.8]) == [0.4, 0.5])
        #expect(L.folded([]) == [0])
        #expect(L.folded([.nan, 7]) == [0.5])
    }

    @Test func spokesAreMirroredLeftRightAndTopBottom() {
        let fractions: [Float] = [0.05, 0.2, 0.45, 0.7, 0.95, 0.6, 0.85, 0.5, 0.3, 0.1]
        let spokes = L.spokeFractions(from: fractions)
        let n = spokes.count
        #expect(n == L.spokeCount)
        for i in 0..<n {
            #expect(abs(spokes[i] - spokes[(n - i) % n]) < 1e-5, "left right \(i)")
            #expect(abs(spokes[i] - spokes[(n / 2 - i + n) % n]) < 1e-5, "top bottom \(i)")
        }
    }

    @Test func theMiddleBarsDriveTheTopAndTheOuterBarsTheSides() {
        var fractions = [Float](repeating: 0, count: 10)
        fractions[4] = 1
        fractions[5] = 1
        let spokes = L.spokeFractions(from: fractions)
        #expect(spokes[0] == 1 && spokes[L.spokeCount / 2] == 1)
        #expect(spokes[L.spokeCount / 4] == 0 && spokes[3 * L.spokeCount / 4] == 0)
        #expect(spokes[1] > 0 && spokes[1] < 1)
        #expect(L.spokeFractions(from: [Float](repeating: 0.5, count: 10)).allSatisfy { abs($0 - 0.5) < 1e-6 })
    }

    @Test(arguments: [PillScale.standard, .large])
    func spokeLengthSpansRestToFullAndClampsBadInput(scale: PillScale) {
        let m = L.Metrics(scale)
        #expect(L.spokeLength(fraction: 0, metrics: m) == m.minSpokeLength)
        #expect(L.spokeLength(fraction: 1, metrics: m) == m.maxSpokeLength)
        #expect(L.spokeLength(fraction: 3, metrics: m) == m.maxSpokeLength)
        #expect(L.spokeLength(fraction: -1, metrics: m) == m.minSpokeLength)
        #expect(L.spokeLength(fraction: .nan, metrics: m) == m.minSpokeLength)
        #expect(m.innerRadius + m.maxSpokeLength < m.diameter / 2)
    }

    @Test func spokeEndsRunOutwardFromTheInnerRadius() {
        let m = L.Metrics.standard
        let centre = CGPoint(x: 100, y: 50)
        let (topIn, topOut) = L.spokeEnds(angle: 0, length: 5, centre: centre, metrics: m)
        #expect(abs(topIn.x - 100) < 1e-9 && abs(topIn.y - 61) < 1e-9 && abs(topOut.y - 66) < 1e-9)
        let (rightIn, rightOut) = L.spokeEnds(angle: .pi / 2, length: 5, centre: centre, metrics: m)
        #expect(abs(rightIn.x - 111) < 1e-9 && abs(rightOut.x - 116) < 1e-9 && abs(rightOut.y - 50) < 1e-9)
    }

    @Test func overallLevelAndDotFollowTheBars() {
        #expect(L.overallLevel([]) == 0)
        #expect(L.overallLevel([Float](repeating: 0, count: 10)) == 0)
        #expect(abs(L.overallLevel(BarModel.weights) - 1) < 1e-5)
        #expect(L.overallLevel([Float](repeating: 1, count: 10)) == 1)
        #expect(L.overallLevel([.nan, .infinity]) == 0)
        let m = L.Metrics.standard
        #expect(L.dotRadius(level: 0, metrics: m) == m.dotRadius)
        #expect(L.dotRadius(level: 1, metrics: m) == m.dotRadius + m.dotPulse)
        #expect(L.dotRadius(level: 0.5, metrics: m) > L.dotRadius(level: 0.2, metrics: m))
        #expect(L.dotRadius(level: 9, metrics: m) == m.dotRadius + m.dotPulse)
    }

    @Test func theLevelArcSweepsFromNothingToAFullCircle() {
        #expect(L.levelSweep(level: 0) == 0)
        #expect(abs(L.levelSweep(level: 0.5) - .pi) < 1e-9)
        #expect(abs(L.levelSweep(level: 1) - 2 * .pi) < 1e-9)
        #expect(L.levelSweep(level: 5) == L.levelSweep(level: 1))
        #expect(L.levelSweep(level: .nan) == 0)
    }

    @Test func settlingIsEasedAndComesToRest() {
        #expect(L.settleProgress(time: 0) == 0)
        #expect(L.settleProgress(time: L.settleDuration) == 1)
        #expect(L.settleProgress(time: 10) == 1)
        #expect(L.settleProgress(time: -1) == 0)
        #expect(L.settleProgress(time: .nan) == 0)
        let a = L.settleProgress(time: 0.05), b = L.settleProgress(time: 0.15)
        #expect(a > 0 && b > a && b < 1)
    }

    @Test func theCometGoesRoundOncePerPeriod() {
        #expect(L.cometHeadAngle(time: 0) == 0)
        #expect(abs(L.cometHeadAngle(time: L.cometPeriod / 4) - .pi / 2) < 1e-9)
        #expect(abs(L.cometHeadAngle(time: L.cometPeriod * 3) - L.cometHeadAngle(time: 0)) < 1e-9)
        #expect(L.cometHeadAngle(time: -2) == 0)
        let stops = L.cometStops()
        #expect(stops.first?.location == 0 && stops.first?.alpha == 0)
        #expect(stops.last?.location == 1 && stops.last?.alpha == 1)
        #expect(stops.map(\.location) == stops.map(\.location).sorted() && stops.map(\.alpha) == stops.map(\.alpha).sorted())
        #expect(abs(stops[1].location - (1 - L.cometSweep / (2 * .pi))) < 1e-9 && stops[1].alpha == 0)
    }

    @Test(arguments: [PillScale.standard, .large])
    func lockedControlsSitAtTheEndsClearOfTheSpokes(scale: PillScale) {
        let m = L.Metrics(scale)
        let capsule = CGRect(x: 0, y: 0, width: L.lockedWidth(metrics: m), height: m.diameter)
        let frames = L.controlFrames(capsule: capsule, metrics: m)
        let cancel = frames[.cancel]!, stop = frames[.stop]!
        #expect(cancel.width == 18 * scale.factor && stop.width == cancel.width)
        #expect(capsule.contains(cancel) && capsule.contains(stop))
        let outer = capsule.midX - (m.innerRadius + m.maxSpokeLength)
        #expect(cancel.maxX < outer && stop.minX > capsule.midX + (capsule.midX - outer))
        #expect(abs(cancel.midY - capsule.midY) < 1e-9)
    }
}

@MainActor
@Suite struct RingPillViewTests {
    private static let loud: [Float] = [0.05, 0.2, 0.45, 0.7, 0.95, 0.6, 0.85, 0.5, 0.3, 0.1]

    private func ring(_ scale: PillScale = .standard, reduceMotion: Bool = false, dark: Bool = true) -> RingPillView {
        FontRegistry.registerBundledFonts()
        let view = RingPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale)), size: scale)
        view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        view.reduceMotionOverride = reduceMotion
        view.appear(reduceMotion: true)
        return view
    }

    @Test func theKindIsWiredEndToEnd() throws {
        #expect(PillSkinKind.ring.title == "Ring" && PillSkinKind.ring.rawValue == "ring")
        #expect(PillSkinKind.ring.pillHeight == 40)
        #expect(PillSkinKind.ring.cardStyle == .classic)
        #expect(!CardStyle.classic.mergesIntoPill)
        let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: .large))
        let view = try PillSkinFactory.make(.ring, frame: frame, scale: .large)
        #expect(view is RingPillView && !view.growsIntoCard)
        #expect((view as? RingPillView)?.pillScale == .large)
    }

    @Test func visibilityFollowsTheModeAndReduceMotion() {
        typealias V = RingPillView.Visibility
        #expect(RingPillView.visibility(mode: .hold, reduceMotion: false) == V(spokes: 1, dot: 1, track: 0, comet: 0, arc: 0, text: 0))
        #expect(RingPillView.visibility(mode: .locked, reduceMotion: false) == RingPillView.visibility(mode: .hold, reduceMotion: false))
        #expect(RingPillView.visibility(mode: .processing, reduceMotion: false) == V(spokes: 0, dot: 1, track: 1, comet: 1, arc: 0, text: 0))
        #expect(RingPillView.visibility(mode: .hold, reduceMotion: true) == V(spokes: 0, dot: 1, track: 1, comet: 0, arc: 1, text: 0))
        #expect(RingPillView.visibility(mode: .processing, reduceMotion: true).comet == 0)
        #expect(RingPillView.visibility(mode: .message(width: 90, height: 40), reduceMotion: false) == V(spokes: 0, dot: 0, track: 0, comet: 0, arc: 0, text: 1))
    }

    @Test(arguments: [PillScale.standard, .large])
    func theRecordingBodyIsACircleAtEachSize(scale: PillScale) {
        let view = ring(scale)
        view.showRecording(locked: false)
        #expect(view.bodySize == CGSize(width: 40 * scale.factor, height: 40 * scale.factor))
        #expect(view.bodyRect.width == view.bodyRect.height)
        #expect(abs(view.bodyRect.midX - view.bounds.midX) <= 1)
        #expect(view.bodyRect.minY == PillGeometry.verticalMargin)
        #expect(view.controlFrames.isEmpty && !view.isLocked)
    }

    @Test func spokesAndDotFollowTheLiveLevel() {
        let view = ring()
        view.showRecording(locked: false)
        view.showFractions([Float](repeating: 0, count: 10))
        #expect(view.spokeLevels.allSatisfy { $0 == 0 } && view.level == 0)
        view.showFractions(Self.loud)
        #expect(view.spokeLevels.max()! > 0.5 && view.level > 0.3)
        view.showFractions([Float](repeating: 0, count: 10))
        #expect(view.level == 0)
    }

    @Test func fractionsAreIgnoredOutsideRecording() {
        let view = ring()
        view.showMessage(PillMessage("Pasted"), overRecording: false)
        view.showFractions(Self.loud)
        #expect(view.level == 0 && view.spokeLevels.allSatisfy { $0 == 0 })
    }

    @Test func processingSettlesTheSpokesAndTheCometTurns() {
        let view = ring()
        view.showRecording(locked: false)
        view.showFractions(Self.loud)
        view.beginProcessing()
        view.updateProcessing(time: 0.1)
        #expect(view.spokeLevels.max()! > 0 && view.spokeLevels.max()! < view.level + 1)
        view.updateProcessing(time: 0.4)
        #expect(view.spokeLevels.allSatisfy { $0 == 0 })
        let first = view.layerTransform(named: "comet")
        view.updateProcessing(time: 0.7)
        #expect(!CATransform3DEqualToTransform(first, view.layerTransform(named: "comet")))
    }

    @Test func reduceMotionHoldsStillAndShowsTheLevelAsOneArc() {
        let view = ring(reduceMotion: true)
        view.showRecording(locked: false)
        view.showFractions(Self.loud)
        let still = view.layerTransform(named: "comet")
        #expect(view.layerOpacity(named: "spokes") == 0 && view.layerOpacity(named: "arc") == 1 && view.layerOpacity(named: "track") == 1)
        let loudArc = view.arcPathBounds
        view.showFractions([Float](repeating: 0.1, count: 10))
        #expect(view.arcPathBounds != loudArc)
        let dot = view.dotPathBounds
        view.showFractions(Self.loud)
        #expect(view.dotPathBounds == dot, "no pulsing")
        view.beginProcessing()
        view.updateProcessing(time: 0.3)
        let a = view.layerTransform(named: "comet")
        view.updateProcessing(time: 0.8)
        #expect(CATransform3DEqualToTransform(a, view.layerTransform(named: "comet")) && CATransform3DEqualToTransform(a, still))
        #expect(view.layerOpacity(named: "comet") == 0 && view.layerOpacity(named: "track") == 1)
    }

    @Test func lockedWidensForTheControls() throws {
        let view = ring()
        view.showRecording(locked: true)
        #expect(view.isLocked)
        let frames = view.controlFrames
        let cancel = try #require(frames[.cancel]), stop = try #require(frames[.stop])
        #expect(view.bodyRect.width == RingPillLayout.lockedWidth(metrics: .standard))
        #expect(view.bounds.contains(PillHit.target(for: cancel)) && view.bounds.contains(PillHit.target(for: stop)))
        #expect(PillHit.control(at: CGPoint(x: cancel.midX, y: cancel.midY), frames: frames) == .cancel)
        #expect(PillHit.control(at: CGPoint(x: stop.midX, y: stop.midY), frames: frames) == .stop)
        view.setHovered(.stop)
        view.setPressed(.cancel)
        view.showRecording(locked: false)
        #expect(view.controlFrames.isEmpty && view.bodyRect.width == 40)
    }

    @Test func aMessageGrowsTheBodyAndKeepsAllItsWords() {
        let view = ring()
        view.showMessage(PillMessage("Pasted"), overRecording: false)
        #expect(view.bodySize.height == 40 && view.bodySize.width >= 64)
        #expect(view.messageLines.map(\.text) == ["Pasted"])
        view.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        #expect(view.bodySize.height > 40)
        #expect(view.messageLines.map(\.text) == ["Mouthtype is busy", "Try again in a moment"])
        #expect(view.messageLines.map(\.isDetail) == [false, true])
        #expect(view.messageSize == view.bodySize)
    }

    @Test func aLongMessageWrapsThenScrollsInsteadOfTruncating() {
        let view = ring()
        let long = String(repeating: "The microphone stopped answering and the model could not finish. ", count: 12)
        view.showMessage(PillMessage("Transcription failed", detail: long, isError: true), overRecording: false)
        #expect(view.bodySize.width <= 320 && view.bodySize.height <= PillGeometry.maxPillSize.height)
        #expect(view.messageLines.count > 3)
        #expect(view.messageScrollDistance > 0)
        let words = view.messageLines.map(\.text).joined(separator: " ").split(separator: " ")
        #expect(words.contains("answering") && !view.messageLines.contains { $0.text.contains("…") })
        view.setMessageOffset(-view.messageScrollDistance)
        view.setMessageOffset(0)
    }

    @Test func largeMessagesAreTwiceTheStandardOnes() {
        let standard = ring(.standard), large = ring(.large)
        for view in [standard, large] { view.showMessage(PillMessage("Pasted"), overRecording: false) }
        #expect(large.bodySize.height == 2 * standard.bodySize.height)
    }

    @Test func overRecordingKeepsTheLockLook() {
        let view = ring()
        view.showRecording(locked: true)
        view.showMessage(PillMessage("Copied"), overRecording: true)
        #expect(view.isLocked && view.controlFrames.isEmpty)
        view.showRecording(locked: true)
        #expect(view.controlFrames.count == 2)
    }

    @Test func switchingAppearanceRecoloursTheInk() throws {
        let view = ring(dark: true)
        view.showRecording(locked: false)
        let dark = view.inkColor
        view.appearance = NSAppearance(named: .aqua)
        #expect(view.inkColor != dark)
        #expect(view.inkColor == SquirclePalette.resolve(.minimal, dark: false).ink.cgColor)
    }

    @Test func theSettingsPreviewBuildsAndStillsTheRing() throws {
        FontRegistry.registerBundledFonts()
        let stage = PillPreviewStage(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
        stage.configure(kind: .ring, scale: .large, readout: .amber, wallpaper: .light)
        #expect(stage.skin is RingPillView && stage.kind == .ring && stage.scale == .large)
        for size in [PillSize.standard, .large] {
            let image = try #require(SettingsPillImage.make(skin: .ring, size: size, wallpaper: .dark))
            #expect(image.size.width == PreviewFit.canvas.width)
            #expect(image.size.height == 40 * size.resolved(visibleWidth: 0).factor + 2 * PillGeometry.verticalMargin)
            #expect(image.size.height <= PreviewFit.canvas.height)
        }
    }

    @Test func disappearCompletes() async {
        let view = ring()
        view.showRecording(locked: false)
        await withCheckedContinuation { continuation in
            view.disappear(reduceMotion: true) { continuation.resume() }
        }
    }
}

/// Writes Ring recording, processing and Reduce Motion pictures when `MOUTHTYPE_RING_PREVIEWS` names a directory, as
/// `mouthtype-ring-*.png` for an eyes pass.
@MainActor
@Suite struct RingPillPreviewTests {
    private static let backing: CGFloat = 4

    private func render(_ view: RingPillView, scale: PillScale, dark: Bool, extra: CGFloat = 0) throws -> CGImage {
        let canvas = PillGeometry.panelSize(for: scale)
        let width = min(canvas.width, (150 + extra) * scale.factor)
        let crop = CGRect(x: (canvas.width - width) / 2, y: 0, width: width, height: 40 * scale.factor + 2 * PillGeometry.verticalMargin)
        let context = try #require(CGContext(
            data: nil, width: Int(crop.width * Self.backing), height: Int(crop.height * Self.backing), bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ))
        context.scaleBy(x: Self.backing, y: Self.backing)
        context.translateBy(x: -crop.minX, y: 0)
        let colors = dark ? [NSColor(hex: 0x3B4A6B).cgColor, NSColor(hex: 0x1D2436).cgColor] : [NSColor(hex: 0xEEF1F5).cgColor, NSColor(hex: 0xC9D2E0).cgColor]
        let gradient = try #require(CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray, locations: [0, 1]))
        context.drawLinearGradient(gradient, start: CGPoint(x: crop.minX, y: crop.height), end: CGPoint(x: crop.maxX, y: 0), options: [])
        view.renderOffscreen(in: context)
        return try #require(context.makeImage())
    }

    private func write(_ image: CGImage, to directory: URL, name: String) throws {
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: directory.appendingPathComponent("mouthtype-ring-" + name + ".png"))
    }

    @Test func everySceneRendersAndOptionallyWritesPNGs() throws {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let directory = ProcessInfo.processInfo.environment["MOUTHTYPE_RING_PREVIEWS"].map { URL(fileURLWithPath: $0, isDirectory: true) }
        if let directory { try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true) }
        let loud: [Float] = [0.1, 0.3, 0.55, 0.8, 1, 0.75, 0.9, 0.5, 0.3, 0.12]
        for scale in [PillScale.standard, .large] {
            let size = scale == .large ? "large" : "standard"
            for dark in [false, true] {
                let look = dark ? "dark" : "light"
                let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
                func fresh(reduceMotion: Bool = false) -> RingPillView {
                    let view = RingPillView(frame: frame, size: scale)
                    view.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                    view.reduceMotionOverride = reduceMotion
                    view.appear(reduceMotion: true)
                    return view
                }
                var scenes: [(String, RingPillView, CGFloat)] = []
                let recording = fresh()
                recording.showRecording(locked: false)
                recording.showFractions(loud)
                scenes.append(("recording-\(size)-\(look)", recording, 0))
                let quiet = fresh()
                quiet.showRecording(locked: false)
                quiet.showFractions([0.04, 0.06, 0.08, 0.1, 0.12, 0.1, 0.08, 0.06, 0.05, 0.03])
                scenes.append(("quiet-\(size)-\(look)", quiet, 0))
                let locked = fresh()
                locked.showRecording(locked: true)
                locked.showFractions(loud)
                scenes.append(("locked-\(size)-\(look)", locked, 0))
                let processing = fresh()
                processing.showRecording(locked: false)
                processing.showFractions(loud)
                processing.beginProcessing()
                processing.updateProcessing(time: 0.9)
                scenes.append(("processing-\(size)-\(look)", processing, 0))
                let reduced = fresh(reduceMotion: true)
                reduced.showRecording(locked: false)
                reduced.showFractions(loud)
                scenes.append(("reduce-motion-\(size)-\(look)", reduced, 0))
                let reducedProcessing = fresh(reduceMotion: true)
                reducedProcessing.beginProcessing()
                reducedProcessing.updateProcessing(time: 0.9)
                scenes.append(("reduce-motion-processing-\(size)-\(look)", reducedProcessing, 0))
                let message = fresh()
                message.showMessage(PillMessage("Pasted"), overRecording: false)
                scenes.append(("message-\(size)-\(look)", message, 40))
                let detail = fresh()
                detail.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
                scenes.append(("message-detail-\(size)-\(look)", detail, 60))
                let error = fresh()
                error.showMessage(PillMessage("Paste failed", isError: true), overRecording: false)
                scenes.append(("error-\(size)-\(look)", error, 40))
                for (name, view, extra) in scenes {
                    let image = try render(view, scale: scale, dark: dark, extra: extra)
                    #expect(image.width > 0)
                    if let directory { try write(image, to: directory, name: name) }
                }
            }
        }
    }
}

/// Test-only reads of the layers the Ring pill draws.
@MainActor
extension RingPillView {
    private func part(_ name: String) -> CALayer {
        switch name {
        case "track": track
        case "arc": arc
        case "spokes": spokes
        case "dot": dot
        default: cometGroup
        }
    }

    func layerOpacity(named name: String) -> Float { part(name).opacity }
    func layerTransform(named name: String) -> CATransform3D { part(name).transform }
    var arcPathBounds: CGRect { arc.path?.boundingBoxOfPath ?? .null }
    var dotPathBounds: CGRect { dot.path?.boundingBoxOfPath ?? .null }
    var inkColor: CGColor? { spokes.strokeColor }
}
