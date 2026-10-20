import AppKit
import SwiftUI

/// The redesign type scale. Instrument Serif for headlines and display words, Instrument Sans for everything else, JetBrains
/// Mono for eyebrows and readouts. The fonts are bundled and registered at launch (`FontRegistry`); when a family did not
/// register, each helper falls back to the system serif, sans or monospaced design so text never disappears.
@MainActor
enum DesignFont {
    /// Page headline, serif.
    static let headline: CGFloat = 28
    /// Card display words and modal page titles, serif. The scale allows 20 to 24.
    static let display: CGFloat = 22
    static let body: CGFloat = 13
    static let detail: CGFloat = 12
    static let caption: CGFloat = 11.5
    /// Eyebrows and readouts, mono.
    static let eyebrow: CGFloat = 10
    /// Smallest size anywhere. 9 is for chart axis labels only.
    static let axis: CGFloat = 9

    /// Eyebrow tracking, .12em at 10 pt.
    static let eyebrowTracking: CGFloat = 1.2

    enum Weight { case regular, medium, semibold }

    private static func installed(_ family: String) -> Bool {
        (FontRegistry.registered ?? FontRegistry.registerBundledFonts()).contains(family)
    }

    static func serif(_ size: CGFloat) -> Font {
        installed("Instrument Serif") ? .custom(FontRegistry.serifName, size: size) : .system(size: size, design: .serif)
    }

    static func sans(_ size: CGFloat, _ weight: Weight = .regular) -> Font {
        guard installed("Instrument Sans") else {
            return .system(size: size, weight: weight == .regular ? .regular : weight == .medium ? .medium : .semibold)
        }
        return .custom(FontRegistry.sansNames[weight == .regular ? 0 : weight == .medium ? 1 : 2], size: size)
    }

    static func mono(_ size: CGFloat) -> Font {
        installed("JetBrains Mono") ? .custom(FontRegistry.monoName, size: size) : .system(size: size, design: .monospaced)
    }
}

extension View {
    /// Mono 10 uppercase, .12em tracking, the third ink. Pass the text as written; the uppercase is applied here.
    func designEyebrow() -> some View {
        font(DesignFont.mono(DesignFont.eyebrow)).tracking(DesignFont.eyebrowTracking).textCase(.uppercase).foregroundStyle(DesignPalette.ink3)
    }
}
