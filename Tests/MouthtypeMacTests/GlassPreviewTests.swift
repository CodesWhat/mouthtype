import AppKit
import Testing
@testable import MouthtypeMac

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = [CGRect]()
    var regions: [CGRect] { lock.lock(); defer { lock.unlock() }; return stored }
    func add(_ region: CGRect) { lock.lock(); stored.append(region); lock.unlock() }
}

private func solidImage(_ grey: UInt8 = 200) -> CGImage? {
        let context = CGContext(data: nil, width: 64, height: 36, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        context?.setFillColor(gray: CGFloat(grey) / 255, alpha: 1)
        context?.fill(CGRect(x: 0, y: 0, width: 64, height: 36))
        return context?.makeImage()
}

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
        let env = PillPreviewStage.systemEnvironment, target = PillPreviewStage.desktopTarget
        let decode = PillPreviewStage.desktopDecode, cache = PillPreviewStage.backdropCache
        defer {
            PillPreviewStage.systemEnvironment = env; PillPreviewStage.desktopTarget = target
            PillPreviewStage.desktopDecode = decode; PillPreviewStage.backdropCache = cache
        }
        PillPreviewStage.systemEnvironment = fakeSystem()
        try await body()
    }

    private func stage(_ wallpaper: PreviewWallpaper, size: PillSize = .standard) -> PillPreviewStage {
        FontRegistry.registerBundledFonts()
        let stage = PillPreviewStage(frame: stageFrame)
        stage.layoutSubtreeIfNeeded()
        stage.configure(kind: .glass, scale: size.resolved(visibleWidth: 0), readout: .amber, wallpaper: wallpaper, size: size)
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
            PillPreviewStage.desktopTarget = { _ in PreviewDesktopTarget(screenID: 1, frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visibleFrame: CGRect(x: 0, y: 25, width: 1440, height: 850), backing: 2, file: URL(fileURLWithPath: "/tmp/none")) }
            PillPreviewStage.desktopDecode = { _, _ in nil }
            for backdrop in [Policy.Backdrop(luminance: 0.5, spread: 0.02), .init(luminance: 0.9, spread: 0.6)] {
                let status = PreviewStatus(source: .desktop, decision: Policy.decide(materialAvailable: true, reduceTransparency: false, backdrop: backdrop), backdrop: backdrop)
                #expect(status.decision?.usesMaterial == true)
            }
        }
    }

    // MARK: Captions

    @Test func captionsNameTheDecisionAndTheReason() {
        func text(_ source: PreviewStatus.Source, _ decision: Policy.Decision?, backdrop: Policy.Backdrop? = .init(luminance: 0.5, spread: 0)) -> String? {
            GlassPreviewCaption.text(PreviewStatus(source: source, decision: decision, backdrop: backdrop))
        }
        #expect(text(.desktop, .glass(.clear)) == "Glass · clear over your desktop")
        #expect(text(.desktop, .glass(.smoked)) == "Glass · smoked over your desktop")
        #expect(text(.desktop, .glass(.smoked), backdrop: nil) == "Glass · smoked: couldn't measure your desktop")
        #expect(text(.light, .glass(.clear)) == "Glass · clear over the Light swatch")
        #expect(text(.dark, .glass(.smoked)) == "Glass · smoked over the Dark swatch")
        #expect(text(.desktop, .solid(.reduceTransparency)) == "Glass · solid: Reduce Transparency")
        #expect(text(.dark, .solid(.materialUnavailable)) == "Glass · solid: material unavailable")
        #expect(text(.desktopLoading, .glass(.smoked)) == "Glass · reading your desktop")
        #expect(text(.desktopFallback, .glass(.smoked))?.contains("Glass · smoked over the Dark swatch") == true)
        #expect(text(.desktopFallback, .glass(.smoked))?.contains("couldn't be read") == true)
        #expect(text(.desktopFallback, nil)?.contains("couldn't be read") == true)
        #expect(text(.light, nil) == nil)
        for decision in [Policy.Decision.glass(.clear), .glass(.smoked), .solid(.materialUnavailable), .solid(.reduceTransparency)] {
            #expect(text(.desktop, decision)?.lowercased().contains("busy") != true)
        }
    }

    // MARK: Desktop

    @Test func desktopIsTheDefaultSwatch() throws {
        let name = "GlassPreview-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SettingsModel(defaults: defaults).previewWallpaper == .desktop)
        #expect(PreviewWallpaper.allCases.map(\.title) == ["Light", "Dark", "Desktop"])
        #expect(PreviewWallpaper.desktop.appearance == nil)
    }

    @Test func desktopDecisionEqualsTheRealPillsForTheSameScreenAndRegion() async throws {
        try await withHooks {
            let screen = try #require(NSScreen.main)
            let target = try #require(PillPreviewStage.desktopTarget(nil), "this machine has a desktop picture")
            for (luminance, expected) in [(0.9, Policy.Decision.glass(.clear)), (0.2, .glass(.smoked)), (0.5, .glass(.smoked))] {
                let recorder = Recorder()
                let measure: GlassBackdropCache.Measure = { _, _, region in
                    recorder.add(region)
                    return Policy.Backdrop(luminance: luminance, spread: 0.3)
                }
                let previewCache = GlassBackdropCache(measure: measure, modificationDate: { _ in nil })
                let pillCache = GlassBackdropCache(measure: measure, modificationDate: { _ in nil })
                PillPreviewStage.backdropCache = previewCache
                PillPreviewStage.desktopDecode = { _, _ in solidImage() }

                let preview = stage(.desktop)
                await spin(until: { preview.desktopState == .ready })
                #expect(preview.desktopState == .ready)
                let previewDecision = try #require((preview.skin as? GlassPillView)?.decision)

                // The real pill: a panel at the placement origin, measured by the production environment.
                let size = PillSize.standard
                let scale = size.resolved(visibleWidth: screen.visibleFrame.width)
                let panel = PillGeometry.panelSize(for: scale)
                let region = GlassBackdropCache.heldRegion(frame: screen.frame, visibleFrame: screen.visibleFrame, backing: screen.backingScaleFactor, size: size)
                let local = GlassPillView.heldBodyRegion(bounds: panel, size: scale, backing: screen.backingScaleFactor)
                let origin = CGPoint(x: region.minX - local.minX, y: region.minY - local.minY)
                let window = NSWindow(contentRect: NSRect(origin: origin, size: panel), styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                var environment = GlassPillEnvironment.system(cache: pillCache)
                environment.materialAvailable = { true }
                environment.reduceTransparency = { false }
                environment.prewarm = {}
                let pill = GlassPillView(frame: NSRect(origin: .zero, size: panel), size: scale, environment: environment)
                window.contentView = pill
                pillCache.prewarm(screen: target.screenID, file: target.file, screenFrame: target.frame, region: region)
                await spin(until: { pillCache.lookup(screen: target.screenID, file: target.file, screenFrame: target.frame, region: region) != .pending })
                pill.refreshBackdrop()

                #expect(previewDecision == pill.decision, "luminance \(luminance)")
                #expect(previewDecision == expected)
                let seen = recorder.regions
                #expect(seen.count == 2 && seen[0] == seen[1], "both measured the same region: \(seen)")
                #expect(seen.first == region)
                window.close()
            }
        }
    }

    @Test func desktopLoadsOffTheMainThreadAndNeverStallsConfigure() async throws {
        try await withHooks {
            let gate = DispatchSemaphore(value: 0)
            let onMain = Recorder()
            PillPreviewStage.desktopDecode = { _, _ in
                if Thread.isMainThread { onMain.add(.zero) }
                gate.wait()
                return solidImage()
            }
            PillPreviewStage.backdropCache = GlassBackdropCache(measure: { _, _, _ in .init(luminance: 0.9, spread: 0) }, modificationDate: { _ in nil })
            let started = Date()
            let stage = stage(.desktop)
            #expect(Date().timeIntervalSince(started) < 1, "configure returned while the loader was still blocked")
            #expect(stage.desktopState == .loading)
            #expect(stage.status?.source == .desktopLoading)
            gate.signal()
            await spin(until: { stage.desktopState == .ready })
            #expect(stage.desktopState == .ready)
            #expect(stage.status?.source == .desktop)
            #expect(onMain.regions.isEmpty, "decode never ran on the main thread")
        }
    }

    @Test func anUnreadableDesktopFallsBackToDarkAndSaysSo() async throws {
        try await withHooks {
            PillPreviewStage.desktopDecode = { _, _ in nil }
            PillPreviewStage.backdropCache = GlassBackdropCache(measure: { _, _, _ in nil }, modificationDate: { _ in nil })
            let stage = stage(.desktop)
            await spin(until: { stage.desktopState == .unreadable })
            #expect(stage.desktopState == .unreadable)
            #expect(stage.effectiveWallpaper == .dark)
            #expect(stage.status?.source == .desktopFallback)
            #expect(stage.status?.decision == .glass(.smoked))
            let caption = try #require(GlassPreviewCaption.text(stage.status))
            #expect(caption.contains("Dark swatch") && caption.contains("couldn't be read"))
        }
    }

    @Test func noDesktopPictureAtAllAlsoFallsBack() async throws {
        try await withHooks {
            PillPreviewStage.desktopTarget = { _ in nil }
            let stage = stage(.desktop)
            #expect(stage.desktopState == .unreadable && stage.effectiveWallpaper == .dark)
            #expect(stage.status?.source == .desktopFallback)
        }
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
