import AppKit
import SwiftUI

/// The redesign colours (handoff 2026-10-20, tokens.json). Every colour is light/dark adaptive, so a view never checks the colour scheme.
/// `DesignPalette.bg` is a SwiftUI `Color`; `DesignPalette.NS.bg` is the same colour as an `NSColor` for AppKit code.
/// With Increase Contrast on, the hairlines and secondary inks step up to meet the 3:1 line / 4.5:1 text guidance.
enum DesignPalette {
    // MARK: Adaptive colours

    enum NS {
        static let bg = pair(light: 0xF3F3F5, dark: 0x1F1F21)
        static let surface = pair(light: 0xFFFFFF, dark: 0x2A2A2C)
        static let ink = pair(light: 0x1D1D1F, dark: 0xF2F2F2)
        static let ink2 = pair(light: 0x5C5C61, dark: 0xB0B0B5, contrastLight: 0x3A3A3E, contrastDark: 0xD8D8DC)
        static let ink3 = pair(light: 0x6B6B70, dark: 0x9A9A9F, contrastLight: 0x45454A, contrastDark: 0xC8C8CC)
        static let hair = pair(light: (0, 0, 0, 0.12), dark: (1, 1, 1, 0.14), contrastLight: (0, 0, 0, 0.45), contrastDark: (1, 1, 1, 0.5))
        static let hair2 = pair(light: (0, 0, 0, 0.07), dark: (1, 1, 1, 0.08), contrastLight: (0, 0, 0, 0.3), contrastDark: (1, 1, 1, 0.34))
        // The website's --lime (#D3E58B): the accent is a fill, never a text colour. Dark ink on it holds ~13:1, but it is only ~1.4:1
        // against white, so a lime shape that has to be seen on a light surface takes a 1px accentMark edge or is drawn in accentMark.
        // accentText and focus are the darker lime for text and the ring.
        static let accent = pair(light: 0xD3E58B, dark: 0xD3E58B)
        static let accentSoft = pair(light: (0xD3, 0xE5, 0x8B, 0.45), dark: (0xD3, 0xE5, 0x8B, 0.16), bytes: true)
        /// Non-text accent: edges, small dots, thin bars and strokes. 3:1 or better on every surface it sits on.
        static let accentMark = pair(light: 0x4A6A12, dark: 0xD3E58B)
        static let onAccent = pair(light: 0x1D1D1F, dark: 0x1F1F21)
        static let accentText = pair(light: 0x4A6A12, dark: 0xA6CD52)
        static let focus = pair(light: 0x4A6A12, dark: 0xA6CD52)
        /// The secondary (--accent-2). Reserved for the lips, the streak flame and warnings.
        static let orange = pair(light: 0xE37512, dark: 0xF19A4B)
        static let success = pair(light: 0x537F5D, dark: 0x6FA57C)
        static let danger = pair(light: 0xD70015, dark: 0xFF564C)
        // High scores. Gold, silver and bronze mark ranks; personal best is a warm chip.
        static let gold = pair(light: 0xBB8C1A, dark: 0xF2B83D)
        static let silver = pair(light: 0x8F939D, dark: 0xC4C6CC)
        static let bronze = pair(light: 0xB8733A, dark: 0xD98C4F)
        static let personalBest = pair(light: 0xFBE9D3, dark: 0x3A2B1B)
        static let personalBestInk = pair(light: 0x6B3A0A, dark: 0xF5C28F)
        static let sel = pair(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.10))
        static let c0 = pair(light: 0xEFF4E4, dark: 0x373E2A)
        static let c1 = pair(light: 0xD3E58B, dark: 0x556535)
        static let c2 = pair(light: 0x76A11A, dark: 0x779041)
        static let c3 = pair(light: 0x5C7E14, dark: 0xA6CD52)
        static let c4 = pair(light: 0x3B4F0E, dark: 0xDBEBBA)
        static let track = pair(light: 0xD9D9DE, dark: 0x3C3C40)
        static let key = pair(light: 0xFFFFFF, dark: 0x38383B)
        static let scrim = pair(light: (0, 0, 0, 0.3), dark: (0, 0, 0, 0.5))
        /// The opaque ground under the sidebar tint (the last layer of `--side`).
        static let sideBase = pair(light: 0xE8E8EC, dark: 0x19191B)
        /// The two translucent stops of the `--side` 165deg gradient.
        static let sideTop = pair(light: (168, 186, 204, 0.42), dark: (70, 92, 112, 0.38), bytes: true)
        static let sideBottom = pair(light: (214, 206, 198, 0.42), dark: (92, 80, 70, 0.38), bytes: true)
        /// Small secondary text on the sidebar wash. `ink2` light is 4.48:1 at the gradient's top end, so this steps just darker to hold 4.5:1.
        static let sideInk = pair(light: 0x58585C, dark: 0xB0B0B5, contrastLight: 0x3A3A3E, contrastDark: 0xD8D8DC)
    }

    static let bg = Color(nsColor: NS.bg)
    static let surface = Color(nsColor: NS.surface)
    static let ink = Color(nsColor: NS.ink)
    static let ink2 = Color(nsColor: NS.ink2)
    static let ink3 = Color(nsColor: NS.ink3)
    static let sideInk = Color(nsColor: NS.sideInk)
    static let hair = Color(nsColor: NS.hair)
    static let hair2 = Color(nsColor: NS.hair2)
    static let accent = Color(nsColor: NS.accent)
    static let accentSoft = Color(nsColor: NS.accentSoft)
    static let onAccent = Color(nsColor: NS.onAccent)
    static let accentMark = Color(nsColor: NS.accentMark)
    static let accentText = Color(nsColor: NS.accentText)
    static let focus = Color(nsColor: NS.focus)
    static let orange = Color(nsColor: NS.orange)
    static let success = Color(nsColor: NS.success)
    static let danger = Color(nsColor: NS.danger)
    static let gold = Color(nsColor: NS.gold)
    static let silver = Color(nsColor: NS.silver)
    static let bronze = Color(nsColor: NS.bronze)
    static let personalBest = Color(nsColor: NS.personalBest)
    static let personalBestInk = Color(nsColor: NS.personalBestInk)
    static let sel = Color(nsColor: NS.sel)
    static let c0 = Color(nsColor: NS.c0)
    static let c1 = Color(nsColor: NS.c1)
    static let c2 = Color(nsColor: NS.c2)
    static let c3 = Color(nsColor: NS.c3)
    static let c4 = Color(nsColor: NS.c4)
    static let track = Color(nsColor: NS.track)
    static let key = Color(nsColor: NS.key)
    static let scrim = Color(nsColor: NS.scrim)
    /// The chart ramp, one lime hue from light (c0) to dark. Charts draw non-highlighted marks in `track`, not from this ramp.
    static let chart: [Color] = [c0, c1, c2, c3, c4]

    /// Chart marks that are not the highlight: grey, so the accent only ever marks the peak or the current item.
    static let neutralMark = ink3.opacity(0.55)

    /// The card drop shadow (`--shadow`).
    static func shadowColor(dark: Bool) -> Color { Color.black.opacity(dark ? 0.3 : 0.05) }

    // MARK: Builders

    private typealias RGBA = (CGFloat, CGFloat, CGFloat, CGFloat)

    private static func hex(_ value: Int) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255, alpha: 1)
    }

    private static func rgba(_ value: RGBA, bytes: Bool) -> NSColor {
        let scale: CGFloat = bytes ? 255 : 1
        return NSColor(srgbRed: value.0 / scale, green: value.1 / scale, blue: value.2 / scale, alpha: value.3)
    }

    private static func pair(light: Int, dark: Int, contrastLight: Int? = nil, contrastDark: Int? = nil) -> NSColor {
        let (l, d) = (hex(light), hex(dark))
        let (cl, cd) = (contrastLight.map(hex) ?? l, contrastDark.map(hex) ?? d)
        return NSColor(name: nil) { appearance in
            let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
        }
    }

    private static func pair(light: RGBA, dark: RGBA, contrastLight: RGBA? = nil, contrastDark: RGBA? = nil, bytes: Bool = false) -> NSColor {
        let (l, d) = (rgba(light, bytes: bytes), rgba(dark, bytes: bytes))
        let (cl, cd) = (contrastLight.map { rgba($0, bytes: bytes) } ?? l, contrastDark.map { rgba($0, bytes: bytes) } ?? d)
        return NSColor(name: nil) { appearance in
            let high = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            return appearance.isDarkAqua ? (high ? cd : d) : (high ? cl : l)
        }
    }
}

extension NSAppearance {
    var isDarkAqua: Bool { bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

/// The frosted sidebar ground (`--side`): a 165deg wash of two translucent tints. `solid` lays it over the opaque base, for Reduce
/// Transparency and offscreen renders where glass cannot draw; otherwise the window's glass shows through the tint.
struct DesignSidebarBackground: View {
    var solid: Bool

    var body: some View {
        ZStack {
            if solid { Color(nsColor: DesignPalette.NS.sideBase) }
            LinearGradient(colors: [Color(nsColor: DesignPalette.NS.sideTop), Color(nsColor: DesignPalette.NS.sideBottom)],
                           startPoint: UnitPoint(x: 0.37, y: 0), endPoint: UnitPoint(x: 0.63, y: 1))
        }
    }
}
