import CoreGraphics
import Foundation
import MouthtypeCore

/// The pixel trophy cup: 24x23 pixels with the 12x12 face sprite in the middle. The cup is the shared shape and the tier marker
/// (bronze, silver or gold body); locked is a dim cup with a silhouette; hidden is the same with a "?".
enum TrophyArt {
    static let width = 24
    static let height = 23
    static let faceOrigin = (x: 6, y: 2)

    enum Face: Equatable {
        case earned(AchievementTier)
        case locked
        case hidden
    }

    /// The colours the art needs for one appearance. The tier hexes are `DesignPalette`'s medal colours.
    struct Palette {
        var tier: [AchievementTier: UInt32]
        var track: UInt32
        var locked: UInt32
        var ink3: UInt32
        var hair: PixelColor

        static let light = Palette(
            tier: [.gold: 0xBB8C1A, .silver: 0x8F939D, .bronze: 0xB8733A], track: 0xD9D9DE, locked: 0xECECEF, ink3: 0x6B6B70,
            hair: PixelColor(hex: 0x000000, alpha: 0.12))
        static let dark = Palette(
            tier: [.gold: 0xF2B83D, .silver: 0xC4C6CC, .bronze: 0xD98C4F], track: 0x3C3C40, locked: 0x323235, ink3: 0x9A9A9F,
            hair: PixelColor(hex: 0xFFFFFF, alpha: 0.14))
    }

    /// The cup template. `k` outline, `T` body, `D` shade, `L` highlight.
    static let cup: [[Character]] = {
        var grid = Array(repeating: Array(repeating: Character("."), count: width), count: height)
        func put(_ x: Int, _ y: Int, _ character: Character) { grid[y][x] = character }
        for y in 0..<16 { for x in 4..<20 { put(x, y, "T") } }
        for x in 4..<20 { put(x, 0, "k") }
        for y in 0..<15 { put(4, y, "k"); put(19, y, "k") }
        for x in 5..<19 { put(x, 14, "T") }
        for x in 4..<20 { put(x, 15, ".") }
        for x in 6..<18 { put(x, 15, "k") }
        for x in [4, 5, 18, 19] { put(x, 14, "k") }
        put(5, 13, "T")
        put(18, 13, "T")
        // Handles, mirrored.
        let handle: [(Int, String)] = [(3, ".kkkk"), (4, "kTTTk"), (5, "kTk.k"), (6, "kTk.k"), (7, "kTk.k"), (8, "kTk.k"), (9, "kTTTk"), (10, ".kkkk")]
        for (y, row) in handle {
            for (index, character) in row.enumerated() where index < 4 && character != "." {
                put(index, y, character)
                put(23 - index, y, character)
            }
        }
        for y in 16..<19 {
            put(9, y, "k")
            put(14, y, "k")
            for x in 10..<14 { put(x, y, "T") }
        }
        for y in 19..<23 { for x in 6..<18 { put(x, y, "T") } }
        for x in 6..<18 { put(x, 19, "k"); put(x, 22, "k") }
        for y in 19..<23 { put(6, y, "k"); put(17, y, "k") }
        for x in 10..<14 { put(x, 18, "T") }
        for y in 2..<14 { put(18, y, "D") }
        for x in 7..<17 { put(x, 21, "D") }
        for y in 17..<19 { put(13, y, "D") }
        for y in 3..<7 { put(5, y, "L") }
        return grid
    }()

    /// A tile's art at one pixel per art pixel. `spriteID` is the achievement's id.
    static func canvas(spriteID: String, face: Face, dark: Bool) -> PixelCanvas {
        let palette = dark ? Palette.dark : Palette.light
        var canvas = PixelCanvas(width: width, height: height)
        let black = PixelColor(hex: 0x000000), white = PixelColor(hex: 0xFFFFFF)

        let body: PixelColor
        let outline: PixelColor
        switch face {
        case .earned(let tier):
            body = PixelColor(hex: palette.tier[tier] ?? 0xBB8C1A)
            outline = PixelColor(hex: 0x1D1D1F)
        case .locked, .hidden:
            body = PixelColor(hex: palette.track)
            outline = palette.hair
        }
        for (y, row) in cup.enumerated() {
            for (x, character) in row.enumerated() {
                switch character {
                case "k": canvas.paint(x, y, outline)
                case "T": canvas.paint(x, y, body)
                case "D": canvas.paint(x, y, body); canvas.paint(x, y, black.withAlpha(0.3))
                case "L": canvas.paint(x, y, body); canvas.paint(x, y, white.withAlpha(0.45))
                default: break
                }
            }
        }

        switch face {
        case .earned:
            canvas.fill(x: faceOrigin.x, y: faceOrigin.y, width: 12, height: 12, PixelColor(hex: 0xF1EEE2))
            guard let rows = AchievementSprites.rows(for: spriteID) else { break }
            canvas.draw(rows, at: faceOrigin) { AchievementSprites.palette[$0].map { PixelColor(hex: $0) } }
        case .locked, .hidden:
            canvas.fill(x: faceOrigin.x, y: faceOrigin.y, width: 12, height: 12, PixelColor(hex: palette.locked))
            let id = face == .hidden ? AchievementSprites.hiddenID : spriteID
            guard let rows = AchievementSprites.rows(for: id) else { break }
            // A silhouette: the outline solid-ish, every fill at 40 percent of that.
            let ink = PixelColor(hex: palette.ink3)
            canvas.draw(rows, at: faceOrigin) { $0 == "k" ? ink.withAlpha(0.6) : ink.withAlpha(0.6 * 0.4) }
        }
        return canvas
    }
}
