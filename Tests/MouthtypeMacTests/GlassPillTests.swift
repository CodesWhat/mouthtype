import AppKit
import Testing
@testable import MouthtypeMac

@Suite struct GlassPillPolicyTests {
    typealias Policy = GlassPillPolicy

    @Test func clearOverLightAndSmokedOverDark() {
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.85, spread: 0.05)) == .glass(.clear))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.1, spread: 0.05)) == .glass(.smoked))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: Policy.lightLimit, spread: 0)) == .glass(.clear))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: Policy.lightLimit - 0.01, spread: 0)) == .glass(.smoked))
    }

    @Test func fallsBackToSolidWhenTheMaterialIsUnavailable() {
        #expect(Policy.decide(materialAvailable: false, reduceTransparency: false, backdrop: .init(luminance: 0.9, spread: 0)) == .solid(.materialUnavailable))
        #expect(Policy.decide(materialAvailable: false, reduceTransparency: true, backdrop: nil) == .solid(.materialUnavailable))
    }

    @Test func fallsBackToSolidUnderReduceTransparency() {
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: true, backdrop: .init(luminance: 0.9, spread: 0)) == .solid(.reduceTransparency))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: true, backdrop: nil) == .solid(.reduceTransparency))
    }

    @Test func theWallpaperNeverMakesGlassSolid() {
        // Mid grey, light but busy, dark but busy: all smoked, none solid.
        for backdrop in [Policy.Backdrop(luminance: 0.5, spread: 0.02), .init(luminance: 0.8, spread: 0.3), .init(luminance: 0.1, spread: 0.3), .init(luminance: 0.61, spread: 0.9)] {
            #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: backdrop).usesMaterial)
        }
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.5, spread: 0.02)) == .glass(.smoked))
        #expect(Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: .init(luminance: 0.1, spread: 0.3)) == .glass(.smoked))
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

    @Test func fallsBackToTheSolidClassicBodyOnlyForSystemReasons() {
        for env in [
            environment(available: false), environment(reduceTransparency: true),
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

private final class SamplerProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var threads: [Bool] = []
    private var date = Date(timeIntervalSince1970: 1_000)
    /// Held shut until a test opens it, so a measurement can be seen to run apart from the caller.
    let gate = DispatchSemaphore(value: 0)
    var waitsForGate = true

    var mainThreadCalls: Int { lock.withLock { threads.filter { $0 }.count } }
    var calls: Int { lock.withLock { threads.count } }
    var modified: Date {
        get { lock.withLock { date } }
        set { lock.withLock { date = newValue } }
    }

    func measured() -> GlassPillPolicy.Backdrop? {
        lock.withLock { threads.append(Thread.isMainThread) }
        if waitsForGate { _ = gate.wait(timeout: .now() + 2) }
        return .init(luminance: 0.1, spread: 0.02)
    }
}

@MainActor
@Suite struct GlassBackdropCacheTests {
    private let file = URL(fileURLWithPath: "/tmp/wallpaper.heic")
    private let frame = CGRect(x: 0, y: 0, width: 1000, height: 600)
    private let region = CGRect(x: 400, y: 20, width: 100, height: 28)

    private func cache(_ probe: SamplerProbe) -> GlassBackdropCache {
        GlassBackdropCache(measure: { _, _, _ in probe.measured() }, modificationDate: { _ in probe.modified })
    }

    @Test func aLookupNeverMeasuresOnTheCallingThread() async {
        let probe = SamplerProbe()
        let cache = cache(probe)
        // The measurement is blocked on the gate, so a synchronous one would hang this call and return ready.
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) == .pending)
        probe.gate.signal()
        let task = cache.prewarm(screen: 1, file: file, screenFrame: frame, region: region)
        #expect(task == nil)
        for _ in 0..<200 where cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) == .pending {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) == .ready(.init(luminance: 0.1, spread: 0.02)))
        #expect(probe.calls == 1 && probe.mainThreadCalls == 0)
    }

    @Test func theKeyIncludesTheModificationTime() async {
        let probe = SamplerProbe()
        probe.waitsForGate = false
        let cache = cache(probe)
        await cache.prewarm(screen: 1, file: file, screenFrame: frame, region: region)?.value
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) != .pending)
        probe.modified = Date(timeIntervalSince1970: 2_000)
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) == .pending)
        #expect(cache.key(file: file, region: region) != GlassBackdropCache.Key(file: file, modified: Date(timeIntervalSince1970: 1_000), region: region))
    }

    @Test func eachScreenAndRegionHasItsOwnEntry() async {
        let probe = SamplerProbe()
        probe.waitsForGate = false
        let cache = cache(probe)
        await cache.prewarm(screen: 1, file: file, screenFrame: frame, region: region)?.value
        await cache.prewarm(screen: 2, file: file, screenFrame: frame, region: region)?.value
        #expect(probe.calls == 2)
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) != .pending)
        #expect(cache.lookup(screen: 2, file: file, screenFrame: frame, region: region) != .pending)
        #expect(cache.lookup(screen: 1, file: file, screenFrame: frame, region: region.offsetBy(dx: 40, dy: 0)) == .pending)
    }

    @Test func aMeasurementAlreadyOnItsWayIsNotStartedTwice() {
        let probe = SamplerProbe()
        let cache = cache(probe)
        _ = cache.lookup(screen: 1, file: file, screenFrame: frame, region: region)
        #expect(cache.prewarm(screen: 1, file: file, screenFrame: frame, region: region) == nil)
        probe.gate.signal()
    }

    @Test func anUnmeasuredWallpaperGetsSmokedGlassWithoutWaiting() {
        let probe = SamplerProbe()
        let cache = cache(probe)
        let environment = GlassPillEnvironment(
            materialAvailable: { true }, reduceTransparency: { false },
            backdrop: { [file, frame, region] _ in
                guard case .ready(let backdrop) = cache.lookup(screen: 1, file: file, screenFrame: frame, region: region) else { return nil }
                return backdrop
            }
        )
        _ = NSApplication.shared
        let glass = GlassPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize), size: .standard, environment: environment)
        glass.appear(reduceMotion: true)
        #expect(glass.decision == .glass(.smoked))
        #expect(glass.showsMaterial)
        probe.gate.signal()
    }
}

@MainActor
@Suite struct GlassSampleRegionTests {
    @Test func theRegionIsTheHeldBodyNotThePanel() {
        for scale in [PillScale.standard, .large] {
            let panel = PillGeometry.panelSize(for: scale)
            let region = GlassPillView.heldBodyRegion(bounds: panel, size: scale, backing: 2)
            let metrics = ClassicPillLayout.Metrics(scale)
            #expect(region.width == ClassicPillLayout.holdWidth(scale: 2, metrics: metrics))
            #expect(region.height == metrics.height && region.minY == PillGeometry.verticalMargin)
            #expect(abs(region.midX - panel.width / 2) <= 0.5)
            #expect(region.width < panel.width / 2)
        }
    }
}

@MainActor
@Suite struct GlassPillMotionTests {
    private func glassView() -> GlassPillView {
        _ = NSApplication.shared
        let environment = GlassPillEnvironment(
            materialAvailable: { true }, reduceTransparency: { false }, backdrop: { _ in .init(luminance: 0.1, spread: 0.02) }
        )
        return GlassPillView(frame: NSRect(origin: .zero, size: PillGeometry.panelSize), size: .standard, environment: environment)
    }

    private func transform(_ animation: CAAnimation?) -> CATransform3D? {
        ((animation as? CABasicAnimation)?.fromValue as? NSValue)?.caTransform3DValue
    }

    @Test func theGlassGrowsFromNinetyPercentAndRisesLikeTheCapsule() throws {
        let view = glassView()
        view.appear(reduceMotion: false)
        let from = try #require(transform(view.glassLayer?.animation(forKey: "transform")))
        #expect(abs(from.m11 - ClassicPillView.appearScale) < 0.001)
        #expect(abs(from.m22 - ClassicPillView.appearScale) < 0.001)
        // Scaling about the middle and dropping 5 pt leaves the middle 5 pt low.
        let layer = try #require(view.glassLayer)
        let size = layer.bounds.size
        let middle = CGPoint(x: (0.5 - layer.anchorPoint.x) * size.width, y: (0.5 - layer.anchorPoint.y) * size.height)
        let moved = CGPoint(
            x: from.m11 * middle.x + from.m41, y: from.m22 * middle.y + from.m42
        )
        #expect(abs(moved.x - middle.x) < 0.001 && abs((middle.y - moved.y) - ClassicPillView.travel) < 0.001)
        #expect(CATransform3DIsIdentity(layer.transform))
    }

    @Test func reduceMotionOnlyFades() {
        let view = glassView()
        view.appear(reduceMotion: true)
        #expect(view.glassLayer?.animation(forKey: "transform") == nil)
        #expect(CATransform3DIsIdentity(view.glassLayer?.transform ?? CATransform3DMakeScale(0, 0, 1)))
    }

    @Test func theGlassShrinksAndDropsOnTheWayOut() throws {
        let view = glassView()
        view.appear(reduceMotion: false)
        view.disappear(reduceMotion: false) {}
        let layer = try #require(view.glassLayer)
        let animation = layer.animation(forKey: "transform") as? CABasicAnimation
        #expect(abs(((animation?.toValue as? NSValue)?.caTransform3DValue.m11 ?? 0) - ClassicPillView.appearScale) < 0.001)
        #expect(abs(layer.transform.m11 - ClassicPillView.appearScale) < 0.001)
    }

    @Test func widthChangesUseTheBodySpring() {
        let view = glassView()
        view.reduceMotionOverride = false
        view.appear(reduceMotion: false)
        view.showRecording(locked: false)
        for key in ["bounds", "position"] {
            let spring = view.glassLayer?.animation(forKey: key) as? CASpringAnimation
            #expect(spring != nil)
            #expect(spring?.stiffness == 331 && spring?.damping == 36.4 && spring?.mass == 1)
        }
    }
}

@MainActor
@Suite struct GlassWallpaperPlaceholderTests {
    @Test func theSystemPlaceholderIsRejected() {
        #expect(GlassBackdropCache.usableWallpaper(URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")) == nil)
        #expect(GlassBackdropCache.usableWallpaper(URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop-Dark.heic")) == nil)
    }

    @Test func realPicturesAreAccepted() {
        for path in [
            "/Users/scott/Pictures/lake.jpg", "/System/Library/Desktop Pictures/Sequoia.heic",
            "/System/Library/CoreServices/Other.heic", "/Users/scott/DefaultDesktop.heic",
        ] {
            let url = URL(fileURLWithPath: path)
            #expect(GlassBackdropCache.usableWallpaper(url) == url, "\(path)")
        }
    }
}
