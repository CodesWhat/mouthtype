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
        static let accent = pair(light: 0x315B54, dark: 0x4F8F82)
        static let accentSoft = pair(light: (0x31, 0x5B, 0x54, 0.10), dark: (0x8F, 0xC1, 0xB5, 0.14), bytes: true)
        static let onAccent = pair(light: 0xFFFFFF, dark: 0x0F1413)
        static let symbol = pair(light: 0x315B54, dark: 0x8FC1B5)
        /// Reserved for the lips and the streak flame.
        static let orange = pair(light: 0xF19A4B, dark: 0xF19A4B)
        static let sel = pair(light: (0, 0, 0, 0.08), dark: (1, 1, 1, 0.10))
        static let c0 = pair(light: 0xE6E6EA, dark: 0x333336)
        static let c1 = pair(light: 0xD6E6E1, dark: 0x2B3A37)
        static let c2 = pair(light: 0xA4C7BE, dark: 0x3E5F58)
        static let c3 = pair(light: 0x6A9D91, dark: 0x4F8F82)
        static let c4 = pair(light: 0x315B54, dark: 0x8FC1B5)
        static let track = pair(light: 0xD9D9DE, dark: 0x3C3C40)
        static let key = pair(light: 0xFFFFFF, dark: 0x38383B)
        static let scrim = pair(light: (0, 0, 0, 0.3), dark: (0, 0, 0, 0.5))
        /// The opaque ground under the sidebar tint (the last layer of `--side`).
        static let sideBase = pair(light: 0xE8E8EC, dark: 0x19191B)
        /// The two translucent stops of the `--side` 165deg gradient.
        static let sideTop = pair(light: (168, 186, 204, 0.42), dark: (70, 92, 112, 0.38), bytes: true)
        static let sideBottom = pair(light: (214, 206, 198, 0.42), dark: (92, 80, 70, 0.38), bytes: true)
    }

    static let bg = Color(nsColor: NS.bg)
    static let surface = Color(nsColor: NS.surface)
    static let ink = Color(nsColor: NS.ink)
    static let ink2 = Color(nsColor: NS.ink2)
    static let ink3 = Color(nsColor: NS.ink3)
    static let hair = Color(nsColor: NS.hair)
    static let hair2 = Color(nsColor: NS.hair2)
    static let accent = Color(nsColor: NS.accent)
    static let accentSoft = Color(nsColor: NS.accentSoft)
    static let onAccent = Color(nsColor: NS.onAccent)
    static let symbol = Color(nsColor: NS.symbol)
    static let orange = Color(nsColor: NS.orange)
    static let sel = Color(nsColor: NS.sel)
    static let c0 = Color(nsColor: NS.c0)
    static let c1 = Color(nsColor: NS.c1)
    static let c2 = Color(nsColor: NS.c2)
    static let c3 = Color(nsColor: NS.c3)
    static let c4 = Color(nsColor: NS.c4)
    static let track = Color(nsColor: NS.track)
    static let key = Color(nsColor: NS.key)
    static let scrim = Color(nsColor: NS.scrim)
    /// The chart ramp, one green hue from light (c0, neutral) to dark.
    static let chart: [Color] = [c0, c1, c2, c3, c4]

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
