import AppKit
import Testing
@testable import MouthtypeMac

@Suite struct GlassPillPolicyTests {
    typealias Policy = GlassPillPolicy

    @Test func clearOverLightAndSmokedOverDark() {
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.85, spread: 0.05)) == .glass(.clear))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.1, spread: 0.05)) == .glass(.smoked))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: Policy.lightLimit, spread: 0)) == .glass(.clear))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: Policy.darkLimit, spread: 0)) == .glass(.smoked))
    }

    @Test func fallsBackToSolidWhenTheMaterialIsUnavailable() {
        #expect(Policy.decide(materialAvailable: false, reduceTransparency: false, backdrop: .init(luminance: 0.9, spread: 0)) == .solid(.materialUnavailable))
        #expect(Policy.decide(materialAvailable: false, reduceTransparency: true, backdrop: nil) == .solid(.materialUnavailable))
    }

    @Test func fallsBackToSolidUnderReduceTransparency() {
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: true, backdrop: .init(luminance: 0.9, spread: 0)) == .solid(.reduceTransparency))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: true, backdrop: nil) == .solid(.reduceTransparency))
    }

    @Test func fallsBackToSolidWhenTheBackdropFailsTheContrastCheck() {
        // Mid grey: neither the dark nor the light ink reads.
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.5, spread: 0.02)) == .solid(.lowContrast))
        // Light but busy.
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.8, spread: 0.3)) == .solid(.lowContrast))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.1, spread: 0.3)) == .solid(.lowContrast))
    }

    @Test func anUnreadableWallpaperGetsSmokedGlass() {
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: nil) == .glass(.smoked))
    }

    @Test func luminanceAndSpreadFromPixels() throws {
        func pixels(_ values: [UInt8]) -> [UInt8] { values.flatMap { [$0, $0, $0, 255] } }
        let white = try #require(Policy.analyze(rgba: pixels([255, 255, 255, 255])))
        #expect(abs(white.luminance - 1) < 0.001 && white.spread < 0.001)
        let black = try #require(Policy.analyze(rgba: pixels([0, 0, 0, 0])))
        #expect(black.luminance < 0.001 && black.spread < 0.001)
        let split = try #require(Policy.analyze(rgba: pixels([0, 0, 255, 255])))
        #expect(abs(split.luminance - 0.5) < 0.001 && abs(split.spread - 0.5) < 0.001)
        #expect(Policy.analyze(rgba: []) == nil)
    }

    @MainActor @Test func cropFollowsTheFilledWallpaper() {
        let screen = CGRect(x: 0, y: 0, width: 200, height: 100)
        // A square picture fills a wide screen by width, so rows are cropped top and bottom.
        let image = CGSize(width: 100, height: 100)
        let bottom = GlassBackdropSampler.cropRect(imageSize: image, screenFrame: screen, region: CGRect(x: 60, y: 0, width: 80, height: 20))
        #expect(bottom.minX == 30 && bottom.width == 40)
        #expect(bottom.maxY > 70 && bottom.maxY <= 100)
        let top = GlassBackdropSampler.cropRect(imageSize: image, screenFrame: screen, region: CGRect(x: 60, y: 80, width: 80, height: 20))
        #expect(top.minY < bottom.minY)
        // A region off the picture falls back to the whole picture.
        let off = GlassBackdropSampler.cropRect(imageSize: image, screenFrame: screen, region: CGRect(x: 500, y: 500, width: 10, height: 10))
        #expect(off == CGRect(origin: .zero, size: image))
    }
}

@MainActor
@Suite struct GlassPillViewTests {
    private func environment(
        available: Bool = true, reduceTransparency: Bool = false, backdrop: GlassPillPolicy.Backdrop? = .init(luminance: 0.1, spread: 0.02)
    ) -> GlassPillEnvironment {
        GlassPillEnvironment(materialAvailable: { available }, reduceTransparency: { reduceTransparency }, backdrop: { _ in backdrop })
    }

    private func view(_ env: GlassPillEnvironment, scale: PillScale = .standard) -> GlassPillView {
        _ = NSApplication.shared
        return GlassPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale)), size: scale, environment: env)
    }

    @Test func usesTheMaterialOverADarkBackdrop() {
        let glass = view(environment())
        glass.appear(reduceMotion: true)
        #expect(glass.decision == .glass(.smoked))
        #expect(glass.showsMaterial && glass.bodyIsGlass)
    }

    @Test func usesClearGlassOverALightBackdrop() {
        let glass = view(environment(backdrop: .init(luminance: 0.9, spread: 0.02)))
        glass.appear(reduceMotion: true)
        #expect(glass.decision == .glass(.clear))
        #expect(glass.showsMaterial)
    }

    @Test func fallsBackToTheSolidClassicBody() {
        for env in [
            environment(available: false), environment(reduceTransparency: true),
            environment(backdrop: .init(luminance: 0.5, spread: 0.01)),
        ] {
            let glass = view(env)
            glass.appear(reduceMotion: true)
            #expect(!glass.decision.usesMaterial)
            #expect(!glass.showsMaterial && !glass.bodyIsGlass)
        }
    }

    @Test func keepsClassicGeometryAndTheSolidStopControl() {
        let classic = ClassicPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize), size: .standard)
        let glass = view(environment())
        for skin in [classic as any PillSkinView, glass] {
            skin.appear(reduceMotion: true)
            skin.showRecording(locked: true)
        }
        #expect(glass.controlFrames == classic.controlFrames)
        #expect(Set(glass.controlFrames.keys) == [.cancel, .stop])
    }

    @Test func largeIsTwiceStandard() {
        let standard = view(environment())
        let large = view(environment(), scale: .large)
        for skin in [standard, large] { skin.appear(reduceMotion: true); skin.showRecording(locked: true) }
        for control in [PillControl.cancel, .stop] {
            #expect(large.controlFrames[control]!.width == standard.controlFrames[control]!.width * 2)
        }
    }

    @Test func messagesLayOutLikeClassic() {
        let glass = view(environment())
        glass.appear(reduceMotion: true)
        glass.showMessage(PillMessage("Mouthtype is busy", detail: "Try again in a moment"), overRecording: false)
        #expect(glass.messageLines.count == 2)
    }

    @Test func controllerBuildsGlassFromThePreference() {
        let controller = makePillController(skin: .glass)
        #expect(controller.skin is GlassPillView && controller.skinKind == .glass)
        controller.showHandsFree()
        #expect(Set(controller.skin.controlFrames.keys) == [.cancel, .stop])
        controller.hide()
    }
}
