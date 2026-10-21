import AppKit

/// Which skin's card is drawn. Hi-Fi draws its own pixel-art window; without its art it wears Classic's colours.
enum CardStyle: Equatable, Sendable {
    case classic, glass, matrix, minimal, hifi

    /// Matrix and Minimal fold the card into the pill: one squircle that grows upward, not a second panel.
    var mergesIntoPill: Bool { self == .matrix || self == .minimal }

    var flavor: SquircleFlavor? {
        switch self {
        case .matrix: .matrix
        case .minimal: .minimal
        case .classic, .glass, .hifi: nil
        }
    }
}

extension PillSkinKind {
    var cardStyle: CardStyle {
        switch self {
        case .classic: .classic
        case .hifi: .hifi
        case .glass: .glass
        case .matrix: .matrix
        case .minimal: .minimal
        }
    }
}

/// A fill that brightens on hover and press: `color` at three alphas.
struct CardTint {
    var color: NSColor
    var rest: CGFloat
    var hover: CGFloat
    var press: CGFloat

    func fill(hovered: Bool, pressed: Bool) -> NSColor {
        color.withAlphaComponent(pressed ? press : hovered ? hover : rest)
    }
}

/// Every colour of the delivery card for one skin and appearance.
@MainActor
struct CardPalette {
    /// Header text, and the quiet accent on a skin that has no other.
    var ink: NSColor
    var body: NSColor
    /// The corrected spelling in a question card.
    var emphasis: NSColor
    /// The status dot and countdown bar: `warn` for a delivery problem, `quiet` for good news, `question` for a question.
    var warn: NSColor
    var quiet: NSColor
    var question: NSColor
    var primaryFill: NSColor
    var primaryText: NSColor
    var secondary: CardTint
    var secondaryText: NSColor
    var dismiss: CardTint
    var dismissGlyph: NSColor
    /// Buttons and dismiss are squircles, not capsules and a disc.
    var squircleControls: Bool
    /// Secondary buttons carry a glass chip's specular edge.
    var chips: Bool
    /// The status dot sits in the header. The squircle cards keep it in the pill's readout row.
    var showsDot: Bool
    /// The standalone card's body and edge; nil where the material or the pill draws the body.
    var bodyFill: NSColor?
    var border: NSColor?
    var shadowFill: NSColor
    /// The readout row's backing and the rule above it, on a card folded into the pill.
    var rowShade: NSColor
    var rowRule: NSColor

    static let amber = NSColor(hex: 0xFFB327)
    static let classicInk = NSColor(hex: 0xF4F3E8)
    static let classicBody = NSColor(hex: 0xF1F0E6)
    static let onInk = NSColor(hex: 0x1D1D1F)
    static let classicWarn = NSColor(hex: 0xFF453A)
    /// The app's v1-pass lime (`DesignPalette.NS.accent` and `onAccent`) for a card's one primary action. The card resolves its own
    /// appearance, so these are fixed per appearance rather than the adaptive colours.
    /// Minimal's lime takes dark ink, so hover and press lighten it (more contrast) where the other skins darken on press.
    var primaryLightens = false

    /// The primary button's fill for a state, as the button draws it.
    func primaryFill(hovered: Bool, pressed: Bool) -> NSColor {
        if primaryLightens {
            return primaryFill.blended(withFraction: pressed ? 0.40 : hovered ? 0.25 : 0, of: .white) ?? primaryFill
        }
        return pressed ? primaryFill.blended(withFraction: 0.18, of: .black) ?? primaryFill
            : hovered ? primaryFill.blended(withFraction: 0.5, of: .white) ?? primaryFill : primaryFill
    }

    static func lime(dark: Bool) -> NSColor { NSColor(hex: dark ? 0xA6CD52 : 0x76A11A) }
    static func onLime(dark: Bool) -> NSColor { NSColor(hex: dark ? 0x1F1F21 : 0x1D1D1F) }

    func accent(for kind: DeliveryCard.Kind) -> NSColor {
        kind.isQuestion ? question : kind.isQuiet ? quiet : warn
    }

    static let classic = CardPalette(
        ink: classicInk, body: classicBody, emphasis: classicInk, warn: classicWarn, quiet: classicInk, question: classicInk,
        primaryFill: classicInk, primaryText: onInk,
        secondary: CardTint(color: NSColor(white: 0.5, alpha: 1), rest: 0.18, hover: 0.30, press: 0.42), secondaryText: classicBody,
        dismiss: CardTint(color: NSColor(white: 0.5, alpha: 1), rest: 0.16, hover: 0.30, press: 0.42),
        dismissGlyph: NSColor(white: 1, alpha: 0.85),
        squircleControls: false, chips: false, showsDot: true,
        bodyFill: ClassicPillView.fill.withAlphaComponent(0.96), border: ClassicPillView.stroke,
        shadowFill: ClassicPillView.fill, rowShade: .clear, rowRule: .clear
    )

    /// `glass` is how the Glass pill's rules decided for the card's backdrop; nil is the solid body.
    static func resolve(style: CardStyle, dark: Bool, glass: GlassPillPolicy.Decision? = nil) -> CardPalette {
        switch style {
        case .classic, .hifi:
            return classic
        case .glass:
            var p = classic
            p.question = amber
            p.secondary = CardTint(color: .white, rest: 0.14, hover: 0.22, press: 0.32)
            p.dismiss = CardTint(color: .white, rest: 0.14, hover: 0.22, press: 0.32)
            p.chips = true
            if case .glass(let variant) = glass {
                p.bodyFill = nil
                p.border = nil
                if variant == .clear {
                    let ink = GlassPillView.clearInk
                    p.ink = ink
                    p.emphasis = ink
                    p.body = NSColor(hex: 0x2C2C2E)
                    p.warn = GlassPillView.clearErrorInk
                    p.quiet = ink
                    p.primaryFill = ink
                    p.primaryText = classicInk
                    p.secondary = CardTint(color: .black, rest: 0.07, hover: 0.12, press: 0.18)
                    p.secondaryText = ink
                    p.dismiss = CardTint(color: .black, rest: 0.07, hover: 0.12, press: 0.18)
                    p.dismissGlyph = ink
                }
            }
            return p
        case .matrix, .minimal:
            let flavor: SquircleFlavor = style == .matrix ? .matrix : .minimal
            let s = SquirclePalette.resolve(flavor, dark: dark)
            let tint = dark ? CardTint(color: .white, rest: 0.10, hover: 0.16, press: 0.24)
                : CardTint(color: .black, rest: 0.07, hover: 0.12, press: 0.18)
            return CardPalette(
                ink: s.text, body: dark ? classicBody : NSColor(hex: 0x2C2C2E), emphasis: s.text,
                warn: s.error, quiet: s.ink, question: s.ink,
                // Matrix keeps its amber. Minimal's one primary action is the app lime; everything else on it is ink or neutral.
                primaryFill: flavor == .matrix ? amber : lime(dark: dark), primaryText: flavor == .matrix ? onInk : onLime(dark: dark),
                secondary: tint, secondaryText: dark ? classicBody : onInk,
                dismiss: tint, dismissGlyph: dark ? .white : onInk,
                squircleControls: true, chips: false, showsDot: false,
                bodyFill: nil, border: nil, shadowFill: .clear,
                rowShade: dark ? NSColor.black.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(0.04),
                rowRule: dark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08),
                primaryLightens: flavor == .minimal
            )
        }
    }
}
