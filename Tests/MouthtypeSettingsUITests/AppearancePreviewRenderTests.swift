import AppKit
import SwiftUI
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct AppearancePreviewRenderTests {
    private func model(
        skin: PillSkinKind, readout: PillReadoutColour = .amber, size: PillSize = .standard,
        wallpaper: PreviewWallpaper = .dark
    ) -> (SettingsModel, UserDefaults, String) {
        let name = "AppearancePreviewRender-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        PillSkinPreference.set(skin, in: defaults)
        PillReadoutPreference.set(readout, in: defaults)
        PillSizePreference.set(size, in: defaults)
        FontRegistry.registerBundledFonts()
        let model = SettingsModel(defaults: defaults)
        model.page = .appearance
        model.previewWallpaper = wallpaper
        return (model, defaults, name)
    }

    private func stage(in view: NSView) -> PillPreviewStage? {
        if let found = view as? PillPreviewStage { return found }
        for child in view.subviews { if let found = stage(in: child) { return found } }
        return nil
    }

    @Test func rendersEveryStyleOverBothSwatchesInBothAppearances() throws {
        for skin in PillSkinKind.allCases {
            for dark in [false, true] {
                for swatch in PreviewWallpaper.allCases {
                    let (model, defaults, name) = model(skin: skin, wallpaper: swatch)
                    defer { defaults.removePersistentDomain(forName: name) }
                    let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark)
                    #expect(bitmap.pixelsWide >= 900 && bitmap.pixelsHigh >= 620)
                    try SettingsRender.save(bitmap, name: "appearance-\(skin.rawValue)-\(dark ? "dark" : "light")-swatch-\(swatch.rawValue)")
                }
            }
        }
    }

    @Test func rendersTheHiFiErrorInEachReadoutColour() throws {
        FontRegistry.registerBundledFonts()
        for readout in PillReadoutColour.allCases {
            let canvas = PreviewFit.canvas
            let height = PillSkinKind.hifi.pillHeight + 2 * PillGeometry.verticalMargin
            let view = try #require(try PillSkinFactory.make(.hifi, frame: NSRect(x: 0, y: 0, width: canvas.width, height: height), scale: .standard, readout: readout))
            view.appear(reduceMotion: true)
            view.showMessage(PillMessage("Mic unavailable", isError: true), overRecording: false)
            let context = try #require(
                CGContext(
                    data: nil, width: Int(canvas.width * 2), height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(NSColor(hex: 0x1D2436).cgColor)
            context.fill(CGRect(x: 0, y: 0, width: canvas.width * 2, height: height * 2))
            context.scaleBy(x: 2, y: 2)
            view.renderOffscreen(in: context)
            let bitmap = NSBitmapImageRep(cgImage: try #require(context.makeImage()))
            try SettingsRender.save(bitmap, name: "appearance-hifi-error-\(readout.rawValue)")
        }
    }

    @Test func rendersEachReadoutColourForHiFi() throws {
        for readout in PillReadoutColour.allCases {
            let (model, defaults, name) = model(skin: .hifi, readout: readout)
            defer { defaults.removePersistentDomain(forName: name) }
            let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: false)
            try SettingsRender.save(bitmap, name: "appearance-hifi-\(readout.rawValue)-light")
            let dark = try SettingsRender.render(model: model, actions: SettingsActions(), dark: true)
            try SettingsRender.save(dark, name: "appearance-hifi-\(readout.rawValue)-dark")
        }
        let (model, defaults, name) = model(skin: .hifi, readout: .coolWhite, size: .large)
        defer { defaults.removePersistentDomain(forName: name) }
        try SettingsRender.save(try SettingsRender.render(model: model, actions: SettingsActions(), dark: false), name: "appearance-hifi-large-light")
    }

    @Test func readoutRowAppearsOnlyForHiFi() throws {
        for skin in PillSkinKind.allCases {
            #expect(skin.hasReadoutColour == (skin == .hifi), "readout row for \(skin)")
        }
    }

    @Test func stageShowsTheSelectedStyleSizeAndReadout() throws {
        let (model, defaults, name) = model(skin: .hifi, readout: .red, size: .large)
        defer { defaults.removePersistentDomain(forName: name) }
        let (view, _) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
        let stage = try #require(stage(in: view))
        #expect(stage.kind == .hifi && stage.scale == .large && stage.readout == .red)
        let hifi = try #require(stage.skin as? HiFiPillView)
        #expect(hifi.artScale == 2)
        model.setSkin(.matrix)
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        #expect(stage.kind == .matrix)
    }

    // MARK: Animation lifecycle

    private func withOnscreenWindow(_ body: () throws -> Void) rethrows {
        let windowCheck = PillPreviewStage.windowOnscreen
        let motion = PillPreviewStage.reduceMotion
        PillPreviewStage.windowOnscreen = { $0 != nil && closedWindows.contains(ObjectIdentifier($0!)) == false }
        PillPreviewStage.reduceMotion = { false }
        closedWindows = []
        defer { PillPreviewStage.windowOnscreen = windowCheck; PillPreviewStage.reduceMotion = motion }
        try body()
    }

    @Test func animationRunsWhileShownAndStopsWhenThePageChanges() throws {
        try withOnscreenWindow {
            let (model, defaults, name) = model(skin: .matrix)
            defer { defaults.removePersistentDomain(forName: name) }
            let (view, _) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
            let stage = try #require(stage(in: view))
            stage.refresh()
            #expect(stage.isAnimating)
            weak var weakStage = stage
            model.page = .home
            view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.1))
            #expect(weakStage?.isAnimating != true)
        }
    }

    @Test func animationStopsWhenTheWindowClosesOrIsCovered() throws {
        try withOnscreenWindow {
            let (model, defaults, name) = model(skin: .glass)
            defer { defaults.removePersistentDomain(forName: name) }
            let (view, window) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
            let stage = try #require(stage(in: view))
            stage.refresh()
            #expect(stage.isAnimating)
            NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
            #expect(!stage.isAnimating)
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            #expect(stage.isAnimating)
            closedWindows.insert(ObjectIdentifier(window))
            NotificationCenter.default.post(name: NSWindow.didChangeOcclusionStateNotification, object: window)
            #expect(!stage.isAnimating)
        }
    }

    @Test func reduceMotionKeepsTheStageStill() throws {
        try withOnscreenWindow {
            let (model, defaults, name) = model(skin: .matrix)
            defer { defaults.removePersistentDomain(forName: name) }
            PillPreviewStage.reduceMotion = { true }
            let (view, _) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
            let stage = try #require(stage(in: view))
            stage.refresh()
            #expect(!stage.isAnimating)
        }
    }

    @Test func aWindowThatIsNotOnScreenNeverAnimates() throws {
        let (model, defaults, name) = model(skin: .classic)
        defer { defaults.removePersistentDomain(forName: name) }
        let (view, _) = SettingsRender.host(model: model, actions: SettingsActions(), dark: false)
        let stage = try #require(stage(in: view))
        stage.refresh()
        #expect(!stage.isAnimating)
    }

    @Test func activityAndFitAreAsSpecified() {
        #expect(PreviewActivity(pageVisible: true, windowOnscreen: true, reduceMotion: false).animates)
        #expect(!PreviewActivity(pageVisible: false, windowOnscreen: true, reduceMotion: false).animates)
        #expect(!PreviewActivity(pageVisible: true, windowOnscreen: false, reduceMotion: false).animates)
        #expect(!PreviewActivity(pageVisible: true, windowOnscreen: true, reduceMotion: true).animates)
        #expect(PreviewFit.scale(availableWidth: 900) == 1)
        #expect(PreviewFit.scale(availableWidth: 220) == 0.5)
        #expect(PreviewFit.caption(size: .large, scale: 1).contains("Large"))
        #expect(PreviewFit.caption(size: .large, scale: 0.5).contains("50% to fit"))
        #expect(PreviewFit.caption(size: .automatic, scale: 1).contains("Standard"))
    }

    @Test func syntheticLevelStaysInRangeAndMoves() {
        var seen = Set<Float>()
        for step in 0..<200 {
            let fractions = PreviewLevel.fractions(at: Double(step) * 0.05)
            #expect(fractions.count == BarModel.barCount)
            #expect(fractions.allSatisfy { $0 >= 0 && $0 <= 1 })
            seen.insert(fractions[4])
        }
        #expect(seen.count > 50)
    }
}

nonisolated(unsafe) private var closedWindows: Set<ObjectIdentifier> = []
