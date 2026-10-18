import AppKit

/// Which squircle pill a palette and its text belong to.
enum SquircleFlavor: Equatable, Sendable {
    case matrix, minimal
}

/// Every colour of the Matrix and Minimal pills for one appearance. Matrix on a light desktop sets the readout in a
/// pager LCD window on a light body; Minimal follows the appearance with plain ink.
struct SquirclePalette {
    var bodyTop: NSColor
    var bodyBottom: NSColor
    var hairline: NSColor
    var highlight: NSColor
    var ambientShadow: Float
    var contactShadow: Float
    /// The readout: dots, bars and the REC label.
    var ink: NSColor
    var rec: NSColor
    var error: NSColor
    /// Message text, the clock's colour and the lips sprite.
    var text: NSColor
    var ghostAlpha: CGFloat
    var glow: NSColor?
    /// The pager LCD window face, top and bottom; nil when the readout sits on the body.
    var window: (top: NSColor, bottom: NSColor)?
    /// Cancel is this colour at 10%, 17% on hover and 26% pressed, with the X in `cancelGlyph`.
    var controlForeground: NSColor
    var cancelGlyph: NSColor
    var finishFill: NSColor
    var finishGlyph: NSColor

    static let darkBody = (top: NSColor(hex: 0x252528), bottom: NSColor(hex: 0x19191B))
    /// A Minimal card on a light desktop: the pill's top, and a bottom lighter than the pill's.
    static let lightCardBottom = NSColor(hex: 0xF0F0F3)
    static let lightBody = (top: NSColor(hex: 0xFBFBFC), bottom: NSColor(hex: 0xE6E6EA))

    static func resolve(_ flavor: SquircleFlavor, dark: Bool) -> SquirclePalette {
        switch (flavor, dark) {
        case (.matrix, true):
            return SquirclePalette(
                bodyTop: darkBody.top, bodyBottom: darkBody.bottom,
                hairline: NSColor.white.withAlphaComponent(0.15), highlight: NSColor.white.withAlphaComponent(0.07),
                ambientShadow: 0.5, contactShadow: 0.35,
                ink: NSColor(hex: 0xFFB327), rec: NSColor(hex: 0xFF4A3C), error: NSColor(hex: 0xFF4A3C),
                text: NSColor(hex: 0xF4F3E8), ghostAlpha: 0.11, glow: NSColor(hex: 0xFF9A10), window: nil,
                controlForeground: NSColor(hex: 0xF4F3E8), cancelGlyph: NSColor(hex: 0xF4F3E8),
                finishFill: NSColor(hex: 0xFFB327), finishGlyph: NSColor(hex: 0x19191B)
            )
        case (.matrix, false):
            return SquirclePalette(
                bodyTop: lightBody.top, bodyBottom: lightBody.bottom,
                hairline: NSColor.black.withAlphaComponent(0.16), highlight: NSColor.white.withAlphaComponent(0.9),
                ambientShadow: 0.2, contactShadow: 0.2,
                ink: NSColor(hex: 0x1D2815), rec: NSColor(hex: 0x1D2815), error: NSColor(hex: 0x6E2312),
                text: NSColor(hex: 0x1D2815), ghostAlpha: 0.09, glow: nil,
                window: (NSColor(hex: 0xBFCAA6), NSColor(hex: 0xAAB691)),
                controlForeground: NSColor(hex: 0x1D1D1F), cancelGlyph: NSColor(hex: 0x1D1D1F).withAlphaComponent(0.72),
                finishFill: NSColor(hex: 0x1D2815), finishGlyph: NSColor(hex: 0xBFCAA6)
            )
        case (.minimal, true):
            return SquirclePalette(
                bodyTop: darkBody.top, bodyBottom: darkBody.bottom,
                hairline: NSColor.white.withAlphaComponent(0.15), highlight: NSColor.white.withAlphaComponent(0.07),
                ambientShadow: 0.5, contactShadow: 0.35,
                ink: NSColor(hex: 0xF4F3E8), rec: NSColor(hex: 0xFF453A), error: NSColor(hex: 0xFF6B5E),
                text: NSColor(hex: 0xF4F3E8), ghostAlpha: 0, glow: nil, window: nil,
                controlForeground: NSColor(hex: 0xF4F3E8), cancelGlyph: NSColor(hex: 0xF4F3E8),
                finishFill: NSColor(hex: 0xF4F3E8), finishGlyph: NSColor(hex: 0x19191B)
            )
        case (.minimal, false):
            return SquirclePalette(
                bodyTop: lightBody.top, bodyBottom: lightBody.bottom,
                hairline: NSColor.black.withAlphaComponent(0.16), highlight: NSColor.white.withAlphaComponent(0.9),
                ambientShadow: 0.2, contactShadow: 0.2,
                ink: NSColor(hex: 0x1D1D1F), rec: NSColor(hex: 0xE0281C), error: NSColor(hex: 0xD70015),
                text: NSColor(hex: 0x1D1D1F), ghostAlpha: 0, glow: nil, window: nil,
                controlForeground: NSColor(hex: 0x1D1D1F), cancelGlyph: NSColor(hex: 0x1D1D1F).withAlphaComponent(0.72),
                finishFill: NSColor(hex: 0x1D1D1F), finishGlyph: NSColor.white
            )
        }
    }
}

/// The 9 x 9 lips sprite that replaces the padlock on a locked pill, from the app icon's small sprite
/// (`design/icon/sprites.py`, LIPS16 before the 1p redraw): the left five columns mirrored about the centre one.
enum LipsSprite {
    static let leftHalf = ["..kk.", ".krrr", "krrrr", "kkkww", "kkkkw", "kkkww", "krrrr", ".krrr", "..kkk"]
    static let size = 9

    /// Rows from the top, nine characters each.
    static let rows: [String] = leftHalf.map { row in row + String(row.dropLast().reversed()) }

    /// Lips and teeth in full `color`, the mouth opening and outline fainter, drawn one point per pixel.
    static func image(color: NSColor) -> CGImage? {
        let ink = color.usingColorSpace(.sRGB) ?? color
        guard let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        for (y, row) in rows.enumerated() {
            for (x, ch) in row.enumerated() {
                let alpha: CGFloat
                switch ch {
                case "r", "p", "R", "w": alpha = 0.92
                case "k": alpha = 0.32
                default: continue
                }
                context.setFillColor(ink.withAlphaComponent(alpha).cgColor)
                context.fill(CGRect(x: x, y: size - 1 - y, width: 1, height: 1))
            }
        }
        return context.makeImage()
    }
}
