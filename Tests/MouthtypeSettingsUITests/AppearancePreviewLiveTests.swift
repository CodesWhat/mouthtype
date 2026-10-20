import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

/// The preview in a real, ordered-front window. Everything is real except the occlusion check: under `swift test` the
/// window server never reports `.visible` (occlusionState stays 8192 even after makeKeyAndOrderFront and activating the
/// app), so `windowOnscreen` falls back to the window's own `isVisible`.
@MainActor @Suite(.serialized) struct AppearancePreviewLiveTests {
    private func onscreen(_ body: () throws -> Void) rethrows {
        let original = PillPreviewStage.windowOnscreen
        PillPreviewStage.windowOnscreen = { window in
            guard let window else { return false }
            return window.isVisible && !window.isMiniaturized
        }
        defer { PillPreviewStage.windowOnscreen = original }
        try body()
    }

    private func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }

    private func stage(in view: NSView) -> PillPreviewStage? {
        if let found = view as? PillPreviewStage { return found }
        for child in view.subviews { if let found = stage(in: child) { return found } }
        return nil
    }

    /// A shown window holding the SwiftUI stage, the way the Settings window holds it.
    private func shownStage(_ kind: PillSkinKind) throws -> (PillPreviewStage, NSWindow) {
        FontRegistry.registerBundledFonts()
        let size = NSSize(width: 480, height: 200)
        let host = NSHostingView(rootView: PillPreviewStageView(kind: kind, size: .standard, readout: .amber, wallpaper: .dark)
            .frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        host.layoutSubtreeIfNeeded()
        spin(0.2)
        return (try #require(stage(in: host)), window)
    }

    /// The width the skin's body was last placed at.
    private func bodyWidth(_ skin: any PillSkinView) -> CGFloat? {
        switch skin {
        case let classic as ClassicPillView: classic.capsuleWidth
        case let glass as GlassPillView: glass.capsuleWidth
        case let squircle as SquirclePillView: squircle.capsuleRect.width
        default: nil
        }
    }

    private func dotWidth(_ kind: PillSkinKind, _ scale: PillScale) -> CGFloat { kind.pillHeight * scale.factor }

    @Test(arguments: PillSkinKind.allCases)
    func everySkinReachesRecordingWidthAndKeepsDrivingInARealWindow(kind: PillSkinKind) throws {
        try onscreen {
                let (stage, window) = try shownStage(kind)
                defer { stage.shutDown(); window.orderOut(nil); window.close() }
                #expect(window.isVisible, "\(kind) window visible")
                #expect(stage.isAnimating, "\(kind) link running")
                #expect(!stage.showsSnapshot, "\(kind) shows the live skin")
                let skin = try #require(stage.skin)
                spin(0.5)
                if let width = bodyWidth(skin) {
                    #expect(width > dotWidth(kind, .standard) + 1, "\(kind) at recording width, not the dot (\(width))")
                }
                let before = stage.framesDriven
                spin(0.5)
                #expect(stage.framesDriven > before, "\(kind) frames driven")
                #expect(skin.layer?.speed == 1, "\(kind) layers running")
        }
    }

    @Test func ringSpokesFollowTheStageLevelInARealWindow() throws {
        try onscreen {
            let (stage, window) = try shownStage(.ring)
            defer { stage.shutDown(); window.orderOut(nil); window.close() }
            let ring = try #require(stage.skin as? RingPillView)
            #expect(stage.isAnimating && !stage.showsSnapshot)
            var seen = Set<[Float]>()
            for _ in 0..<8 {
                spin(0.1)
                seen.insert(ring.spokeLevels)
            }
            #expect(seen.count > 2, "spokes keep moving with the preview level")
            #expect(ring.spokeLevels.max() ?? 0 > 0 && ring.level > 0)
        }
    }

    @Test func matrixLampBreathesWhileTheStageRuns() throws {
        try onscreen {
            let (stage, window) = try shownStage(.matrix)
            defer { stage.shutDown(); window.orderOut(nil); window.close() }
            let matrix = try #require(stage.skin as? MatrixPillView)
            spin(0.3)
            #expect(matrix.lampAnimation != nil)
            #expect(stage.skin?.layer?.speed == 1)
        }
    }

    @Test func theEntranceWaitsForTheStageToBeOnScreen() throws {
        try onscreen {
            FontRegistry.registerBundledFonts()
            let stage = PillPreviewStage(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
            stage.configure(kind: .classic, scale: .standard, readout: .amber, wallpaper: .dark)
            let classic = try #require(stage.skin as? ClassicPillView)
            #expect(!stage.isAnimating && stage.showsSnapshot)
            let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: 200, y: 200), size: PreviewFit.canvas), styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView?.addSubview(stage)
            window.makeKeyAndOrderFront(nil)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            spin(0.3)
            defer { stage.shutDown(); window.orderOut(nil); window.close() }
            #expect(stage.isAnimating)
            #expect(classic.capsuleWidth > dotWidth(.classic, .standard) + 1)
        }
    }

    /// Classic's appear() places the pill as a dot, so the recording state has to come after it. This is the order the
    /// stage used to get wrong: state first leaves the body at the dot width for good.
    @Test func classicNeedsAppearBeforeTheRecordingState() throws {
        try onscreen {
            FontRegistry.registerBundledFonts()
            let frame = NSRect(x: 0, y: 0, width: PreviewFit.canvas.width, height: 60)
            let right = try #require(try PillSkinFactory.make(.classic, frame: frame, scale: .standard) as? ClassicPillView)
            right.appear(reduceMotion: false)
            right.showRecording(locked: false)
            let wrong = try #require(try PillSkinFactory.make(.classic, frame: frame, scale: .standard) as? ClassicPillView)
            wrong.showRecording(locked: false)
            wrong.appear(reduceMotion: false)
            #expect(right.capsuleWidth > wrong.capsuleWidth + 1)
            #expect(wrong.capsuleWidth == dotWidth(.classic, .standard))
        }
    }

    @Test func switchingPagesBackStartsTheLinkAgain() throws {
        try onscreen {
            let (stage, window) = try shownStage(.glass)
            defer { stage.shutDown(); window.orderOut(nil); window.close() }
            #expect(stage.isAnimating)
            stage.pageVisible = false
            #expect(!stage.isAnimating)
            stage.pageVisible = true
            #expect(stage.isAnimating)
            spin(0.4)
            #expect(stage.skin?.layer?.speed == 1)
        }
    }
}
