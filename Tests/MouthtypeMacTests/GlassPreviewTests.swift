import AppKit
import Testing
@testable import MouthtypeMac

/// The Appearance preview's Glass decision is the real policy's, over the swatch the user picked.
@MainActor
@Suite(.serialized) struct GlassPreviewTests {
    private typealias Policy = GlassPillPolicy
    private let stageFrame = NSRect(x: 0, y: 0, width: 500, height: 156)

    private func fakeSystem(reduceTransparency: Bool = false, available: Bool = true) -> GlassPillEnvironment {
        GlassPillEnvironment(materialAvailable: { available }, reduceTransparency: { reduceTransparency }, backdrop: { _ in nil })
    }

    private func spin(until condition: () -> Bool, timeout: TimeInterval = 5) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition(), Date() < end { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func withHooks(_ body: () async throws -> Void) async rethrows {
        let env = PillPreviewStage.systemEnvironment, cache = PillPreviewStage.backdropCache
        defer { PillPreviewStage.systemEnvironment = env; PillPreviewStage.backdropCache = cache }
        PillPreviewStage.systemEnvironment = fakeSystem()
        try await body()
    }

    private func stage(_ wallpaper: PreviewWallpaper, size: PillSize = .standard) -> PillPreviewStage {
        FontRegistry.registerBundledFonts()
        let stage = PillPreviewStage(frame: stageFrame)
        stage.layoutSubtreeIfNeeded()
        stage.configure(kind: .glass, scale: size.resolved(visibleWidth: 0), readout: .amber, wallpaper: wallpaper)
        return stage
    }

    // MARK: Swatches

    @Test func lightAndDarkSwatchesAnalyseToTheRealPolicysDecision() async throws {
        try await withHooks {
            for (wallpaper, expected) in [(PreviewWallpaper.light, Policy.Decision.glass(.clear)), (.dark, .glass(.smoked))] {
                let stage = stage(wallpaper)
                let glass = try #require(stage.skin as? GlassPillView)
                let backdrop = try #require(stage.glassBackdrop, "\(wallpaper) has a measured backdrop")
                #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: backdrop) == expected, "\(wallpaper) \(backdrop)")
                #expect(glass.decision == expected)
                #expect(stage.status?.decision == expected)
                #expect(stage.status?.source == (wallpaper == .light ? .light : .dark))
            }
        }
    }

    @Test func swatchBackdropsUseTheRealAnalysisOverTheirOwnPixels() throws {
        let size = CGSize(width: 500, height: 156)
        let region = CGRect(x: 150, y: 10, width: 200, height: 40)
        let light = try #require(PreviewSwatch.backdrop(of: .light, size: size, region: region))
        let dark = try #require(PreviewSwatch.backdrop(of: .dark, size: size, region: region))
        #expect(light.luminance >= Policy.lightLimit && dark.luminance < Policy.lightLimit)
        #expect(light.luminance > dark.luminance + 0.3)
        #expect(light.luminance != dark.luminance && light.spread >= 0 && dark.spread >= 0)
    }

    @Test func reduceTransparencyGoesSolidWithItsReason() async throws {
        try await withHooks {
            PillPreviewStage.systemEnvironment = fakeSystem(reduceTransparency: true)
            let stage = stage(.light)
            #expect(stage.status?.decision == .solid(.reduceTransparency))
            #expect(GlassPreviewCaption.text(stage.status) == "Glass · solid: Reduce Transparency")
        }
    }

    @Test func aMidToneOrBusyBackdropIsSmokedNeverSolid() async throws {
        try await withHooks {
            for backdrop in [Policy.Backdrop(luminance: 0.5, spread: 0.02), .init(luminance: 0.9, spread: 0.6)] {
                let status = PreviewStatus(source: .dark, decision: Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: backdrop), backdrop: backdrop)
                #expect(status.decision?.usesMaterial == true)
            }
        }
    }

    // MARK: Captions

    @Test func captionsNameTheDecisionAndTheReason() {
        func text(_ source: PreviewStatus.Source, _ decision: Policy.Decision?, backdrop: Policy.Backdrop? = .init(luminance: 0.5, spread: 0)) -> String? {
            GlassPreviewCaption.text(PreviewStatus(source: source, decision: decision, backdrop: backdrop))
        }
        #expect(text(.light, .glass(.clear)) == "Glass · clear over the Light swatch")
        #expect(text(.dark, .glass(.smoked)) == "Glass · smoked over the Dark swatch")
        #expect(text(.light, .solid(.reduceTransparency)) == "Glass · solid: Reduce Transparency")
        #expect(text(.dark, .solid(.materialUnavailable)) == "Glass · solid: material unavailable")
        #expect(text(.light, nil) == nil)
        for decision in [Policy.Decision.glass(.clear), .glass(.smoked), .solid(.materialUnavailable), .solid(.reduceTransparency)] {
            #expect(text(.dark, decision)?.lowercased().contains("busy") != true)
        }
    }

    // MARK: Swatch picker

    @Test func darkIsTheDefaultSwatchAndThePickerOffersOnlyLightAndDark() throws {
        let name = "GlassPreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsModel(defaults: defaults).previewWallpaper == .dark)
        #expect(PreviewWallpaper.allCases.map(\.title) == ["Light", "Dark"])
        #expect(PreviewWallpaper(rawValue: "desktop") == nil)
    }

    @Test func theSwatchIsASiblingBehindThePillSoTheMaterialCanRefractIt() async throws {
        try await withHooks {
            let stage = stage(.light)
            let order = stage.subviews
            let backdrop = try #require(order.first)
            #expect(backdrop.layer?.contents != nil)
            #expect(order.firstIndex(of: backdrop)! < order.firstIndex(where: { $0.subviews.contains { $0 === stage.skin } })!)
        }
    }

    @Test func theSnapshotUsesTheInjectedBackdrop() throws {
        let dark = GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { false }, backdrop: { _ in .init(luminance: 0.1, spread: 0) })
        let light = GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { false }, backdrop: { _ in .init(luminance: 0.9, spread: 0) })
        let solid = GlassPillEnvironment(materialAvailable: { true }, reduceTransparency: { true }, backdrop: { _ in nil })
        for env in [dark, light, solid] {
            #expect(SettingsPillImage.make(skin: .glass, size: .standard, wallpaper: .dark, glassEnvironment: env) != nil)
        }
    }
}
