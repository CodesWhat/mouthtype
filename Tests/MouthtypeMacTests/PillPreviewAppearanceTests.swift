import AppKit
import Testing
@testable import MouthtypeMac

/// The Appearance preview shows a pill over a light or dark swatch, so the pill has to resolve its palette from the
/// swatch and not from the window or the process.
@MainActor
@Suite(.serialized) struct PillPreviewAppearanceTests {
    private func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private func configured(_ kind: PillSkinKind, wallpaper: PreviewWallpaper) -> PillPreviewStage {
        let stage = PillPreviewStage(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
        stage.configure(kind: kind, scale: .standard, readout: .amber, wallpaper: wallpaper)
        return stage
    }

    @Test func squircleSkinsResolveTheSwatchPaletteInEitherMode() throws {
        for kind in [PillSkinKind.matrix, .minimal] {
            for wallpaper in PreviewWallpaper.allCases {
                // The window's own appearance is the opposite of the swatch.
                let host = NSWindow(contentRect: NSRect(origin: .zero, size: PreviewFit.canvas), styleMask: [.titled], backing: .buffered, defer: true)
                host.appearance = wallpaper == .desktop ? NSAppearance(named: .aqua) : (wallpaper == .dark ? PreviewWallpaper.light : .dark).appearance
                let stage = PillPreviewStage(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
                host.contentView?.addSubview(stage)
                stage.configure(kind: kind, scale: .standard, readout: .amber, wallpaper: wallpaper)
                let skin = try #require(stage.skin as? SquirclePillView)
                let expected = SquirclePalette.resolve(skin.flavor, dark: wallpaper == .dark)
                #expect(skin.resolvedPalette.bodyTop == expected.bodyTop, "\(kind) over \(wallpaper)")
                #expect(skin.resolvedPalette.ink == expected.ink, "\(kind) over \(wallpaper)")
            }
        }
        let dark = try #require(configured(.matrix, wallpaper: .dark).skin as? SquirclePillView).resolvedPalette
        let light = try #require(configured(.matrix, wallpaper: .light).skin as? SquirclePillView).resolvedPalette
        #expect(dark.bodyTop != light.bodyTop)
    }

    @Test func glassFollowsTheSwatchAppearance() throws {
        for wallpaper in PreviewWallpaper.allCases {
            let skin = try #require(configured(.glass, wallpaper: wallpaper).skin)
            // Desktop follows the system, as the real pill does.
            let expected = wallpaper == .desktop ? isDark(NSApplication.shared.effectiveAppearance) : wallpaper == .dark
            #expect(isDark(skin.effectiveAppearance) == expected)
        }
    }

    @Test func aSwatchOnlyChangeRebuildsTheSkin() throws {
        let stage = configured(.matrix, wallpaper: .dark)
        let first = try #require(stage.skin)
        stage.configure(kind: .matrix, scale: .standard, readout: .amber, wallpaper: .dark)
        #expect(stage.skin === first)
        stage.configure(kind: .matrix, scale: .standard, readout: .amber, wallpaper: .light)
        #expect(stage.skin !== first)
        #expect(stage.wallpaper == .light)
    }

    @Test func theOffscreenSnapshotFollowsTheSwatch() throws {
        func meanLuminance(_ image: NSImage?) throws -> Double {
            let cg = try #require(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
            let rep = NSBitmapImageRep(cgImage: cg)
            var total = 0.0, count = 0.0
            for y in 0..<rep.pixelsHigh { for x in 0..<rep.pixelsWide {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB), c.alphaComponent > 0.9 else { continue }
                total += 0.2126 * Double(c.redComponent) + 0.7152 * Double(c.greenComponent) + 0.0722 * Double(c.blueComponent)
                count += 1
            } }
            return count > 0 ? total / count : 0
        }
        for kind in [PillSkinKind.matrix, .minimal] {
            let dark = try meanLuminance(SettingsPillImage.make(skin: kind, size: .standard, wallpaper: .dark))
            let light = try meanLuminance(SettingsPillImage.make(skin: kind, size: .standard, wallpaper: .light))
            #expect(light > dark + 0.15, "\(kind) snapshot light \(light) dark \(dark)")
        }
    }

    @Test func aRebuiltSkinIsFrozenWhenNoLinkRuns() throws {
        // An unhosted stage has no window, so no display link ever starts.
        let stage = PillPreviewStage(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
        for kind in [PillSkinKind.matrix, .minimal, .matrix] {
            stage.configure(kind: kind, scale: .standard, readout: .amber, wallpaper: .dark)
            #expect(!stage.isAnimating)
            #expect(stage.skin?.layer?.speed == 0, "\(kind)")
        }
    }
}
