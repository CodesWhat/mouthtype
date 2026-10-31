import AppKit
import QuartzCore

/// A control the card draws itself and tracks the mouse for, so it works in a panel that never becomes key: it
/// accepts the first click, reports hover through an always-active tracking area, and fires on mouse-up inside.
@MainActor
class CardControlView: NSView {
    var onClick: (@MainActor () -> Void)?
    private(set) var isHovered = false
    private(set) var isPressed = false
    var isActive = true { didSet { needsDisplay = true } }
    var palette = CardPalette.classic { didSet { needsDisplay = true } }
    /// The pill size's multiple, for the drawn glyph and corners.
    var k: CGFloat = 1 { didSet { needsDisplay = true } }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func isAccessibilityEnabled() -> Bool { isActive }
    override func accessibilityPerformPress() -> Bool {
        guard isActive, let onClick else { return false }
        onClick()
        return true
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(
            NSTrackingArea(
                rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil
            ))
    }

    override func mouseEntered(with event: NSEvent) { set(hovered: true, pressed: isPressed) }
    override func mouseExited(with event: NSEvent) { set(hovered: false, pressed: isPressed) }

    override func mouseDown(with event: NSEvent) {
        guard isActive else { return }
        set(hovered: isHovered, pressed: true)
    }

    override func mouseDragged(with event: NSEvent) {
        guard isPressed else { return }
        set(hovered: isHovered, pressed: bounds.contains(convert(event.locationInWindow, from: nil)))
    }

    override func mouseUp(with event: NSEvent) {
        guard isPressed else { return }
        let inside = bounds.contains(convert(event.locationInWindow, from: nil))
        set(hovered: isHovered, pressed: false)
        if inside { onClick?() }
    }

    private func set(hovered: Bool, pressed: Bool) {
        isHovered = hovered
        isPressed = pressed
        needsDisplay = true
    }

    /// Fills the control's shape: the capsule or disc of the round skins, a squircle of `radius` on the others.
    func fillShape(in rect: CGRect, radius: CGFloat, round: Bool, color: NSColor) {
        color.setFill()
        if palette.squircleControls {
            guard let context = NSGraphicsContext.current?.cgContext else { return }
            context.addPath(MatrixPillLayout.squirclePath(rect, reference: radius / MatrixPillLayout.cornerFactor))
            context.fillPath()
        } else if round {
            NSBezierPath(ovalIn: rect).fill()
        } else {
            NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        }
    }
}

/// The 24 pt dismiss control: a disc, or a squircle on the squircle cards.
@MainActor
final class CardDismissView: CardControlView {
    override func accessibilityLabel() -> String? { "Dismiss" }

    override func draw(_ dirtyRect: NSRect) {
        fillShape(in: bounds, radius: 9 * k, round: true, color: palette.dismiss.fill(hovered: isHovered, pressed: isPressed))
        let c = CGPoint(x: bounds.midX, y: bounds.midY), h: CGFloat = 3.2 * k
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: c.x - h, y: c.y - h))
        cross.line(to: CGPoint(x: c.x + h, y: c.y + h))
        cross.move(to: CGPoint(x: c.x - h, y: c.y + h))
        cross.line(to: CGPoint(x: c.x + h, y: c.y - h))
        cross.lineWidth = 1.6 * k
        cross.lineCapStyle = .round
        palette.dismissGlyph.setStroke()
        cross.stroke()
    }
}

/// A text button: the first of a card's buttons is the filled primary, the rest the quiet kind.
@MainActor
final class CardButtonView: CardControlView {
    var label = NSAttributedString()
    override func accessibilityLabel() -> String? { label.string }
    var isPrimary = true

    override func draw(_ dirtyRect: NSRect) {
        let scale: CGFloat = isPressed ? 0.97 : 1
        let rect = bounds.insetBy(dx: bounds.width * (1 - scale) / 2, dy: bounds.height * (1 - scale) / 2)
        let fill: NSColor
        if isPrimary {
            fill = palette.primaryFill(hovered: isHovered, pressed: isPressed)
        } else {
            fill = palette.secondary.fill(hovered: isHovered, pressed: isPressed)
        }
        fillShape(in: rect, radius: 10 * k, round: false, color: fill)
        if isPrimary, let edge = palette.primaryEdge, let context = NSGraphicsContext.current?.cgContext {
            // A 1px ring in the same squircle the fill uses.
            context.saveGState()
            context.addPath(MatrixPillLayout.squirclePath(rect, reference: 10 * k / MatrixPillLayout.cornerFactor))
            context.addPath(MatrixPillLayout.squirclePath(rect.insetBy(dx: 1, dy: 1), reference: 9 * k / MatrixPillLayout.cornerFactor))
            context.setFillColor(edge.cgColor)
            context.fillPath(using: .evenOdd)
            context.restoreGState()
        }
        if !isPrimary, palette.chips, let context = NSGraphicsContext.current?.cgContext {
            // The glass chip's specular edge along its top.
            context.saveGState()
            context.addPath(CGPath(roundedRect: rect, cornerWidth: rect.height / 2, cornerHeight: rect.height / 2, transform: nil))
            context.clip()
            context.setFillColor(NSColor.white.withAlphaComponent(0.35).cgColor)
            context.fill(CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: 0.6 * k))
            context.restoreGState()
        }
        let size = label.size()
        label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

/// What the pill's readout row says while a card is folded into it: the short thing, not the header again.
struct CardReadout: Equatable, Sendable {
    enum Tone: Equatable, Sendable { case alert, quiet, question }

    /// "SAFE" over a transcript, the clock over a countdown, nothing otherwise.
    var label: String
    var isClock: Bool
    var tone: Tone
    /// The countdown bar's fill, 1 down to 0; nil when the card has no countdown.
    var progress: CGFloat?
}

/// The card: the surface, the reason line with its status dot, the transcript, the buttons and the dismiss control,
/// laid out by `CardLayout` at the pill's size. It draws in the colours of the skin it is configured for. As a
/// standalone card the view fills its panel, with the face inset by the shadow margin. Folded into a pill
/// (`embedded`) it draws only the face's content, on the pill's own body, and is exactly the face's size.
@MainActor
final class DeliveryCardView: NSView {
    var onAction: (@MainActor (CardAction) -> Void)?
    var onDismiss: (@MainActor () -> Void)?

    private let environment: GlassPillEnvironment
    private let glass = NSGlassEffectView()
    private let shadows = CALayer()
    private let ambient = CALayer()
    private let contact = CALayer()
    private let body = CALayer()
    private let content = FlippedView()
    private let dot = CALayer()
    private let header = NSTextField(wrappingLabelWithString: "")
    private let dismiss = CardDismissView()
    private let scroll = NSScrollView()
    private let textView = NSTextView()
    private var buttons: [(action: CardAction, view: CardButtonView)] = []
    private let barClip = CALayer()
    private let barFill = CALayer()

    private var state: CardViewState?
    private var typography = Typography.current()
    /// When the Undo clock started, shared with the card's other view so a skin change doesn't restart it.
    private(set) var countdownStart: CFTimeInterval?
    /// The tallest the face may be; a longer transcript scrolls to fit. Set for a card folded into a pill on a short screen.
    var maxFaceHeight: CGFloat?
    private var backdrop: GlassPillPolicy.Backdrop?
    private(set) var frames: CardLayout.Frames?
    private(set) var style = CardStyle.classic
    private(set) var pillScale = PillScale.standard
    private(set) var embedded = false
    /// The Hi-Fi readout colour the Hi-Fi card's text and bar wear.
    private(set) var hifiReadout = PillReadoutColour.default
    /// The Hi-Fi card's window, built when the skin first asks for it; nil without its art.
    private(set) var hifi: HiFiCardView?
    private(set) var palette = CardPalette.classic
    private(set) var glassDecision: GlassPillPolicy.Decision = .solid(.materialUnavailable)
    /// The face size, without the shadow margin.
    var faceSize: CGSize { showsHiFi ? hifi?.faceSize ?? .zero : frames?.size ?? .zero }
    /// True while the Hi-Fi window is the card's body.
    var showsHiFi: Bool { style == .hifi && hifi != nil && !embedded && hifiCanDraw }
    /// False when the current card has text the pixel face can't draw: that delivery wears the Classic card.
    private(set) var hifiCanDraw = true
    /// True while the system glass material is the card's body.
    var showsMaterial: Bool { !glass.isHidden }
    var showsDot: Bool { !dot.isHidden }
    /// The drop shadow layers' paths, for tests.
    var shadowPaths: [CGPath?] { [ambient.shadowPath, contact.shadowPath] }

    private var k: CGFloat { pillScale.factor }
    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    init(frame: NSRect, environment: GlassPillEnvironment = .system) {
        self.environment = environment
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        glass.isHidden = true
        addSubview(glass)
        layer?.addSublayer(shadows)
        for (shadow, opacity) in [(ambient, Float(0.50)), (contact, 0.35)] {
            shadow.backgroundColor = ClassicPillView.fill.cgColor
            shadow.cornerCurve = .continuous
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = opacity
            shadows.addSublayer(shadow)
        }
        body.cornerCurve = .continuous
        layer?.addSublayer(body)

        addSubview(content)
        dot.shadowOpacity = 0.9
        dot.shadowOffset = .zero
        content.wantsLayer = true
        content.layer?.addSublayer(dot)

        header.isSelectable = false
        header.maximumNumberOfLines = 0
        header.lineBreakMode = .byWordWrapping
        header.drawsBackground = false
        content.addSubview(header)

        dismiss.onClick = { [weak self] in self?.onDismiss?() }
        content.addSubview(dismiss)

        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.scrollerStyle = .overlay
        scroll.scrollerKnobStyle = .light
        scroll.autohidesScrollers = true
        scroll.verticalScrollElasticity = .none
        textView.isEditable = false
        textView.isSelectable = false
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.textContainer?.widthTracksTextView = true
        scroll.documentView = textView
        content.addSubview(scroll)

        // The countdown bar is clipped to the card's rounded shape and drains along its bottom edge.
        barClip.cornerCurve = .continuous
        barClip.masksToBounds = true
        barClip.addSublayer(barFill)
        layer?.addSublayer(barClip)
        resolvePalette()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        restyle()
    }

    /// Picks the skin, size and whether the card is folded into a pill. Takes effect at the next `render`.
    func configure(style: CardStyle, scale: PillScale, embedded: Bool, readout: PillReadoutColour = .default) {
        self.style = style
        pillScale = scale
        self.embedded = embedded
        hifiReadout = readout
        if style == .hifi, hifi == nil, let assets = HiFiCardAssets.shared {
            let window = HiFiCardView(assets: assets)
            window.onAction = { [weak self] in self?.onAction?($0) }
            window.onDismiss = { [weak self] in self?.onDismiss?() }
            content.addSubview(window)
            hifi = window
        }
        resolvePalette()
    }

    /// Samples the wallpaper under the card once and decides the Glass card's material again. Runs when the card shows.
    func refreshBackdrop() {
        guard style == .glass else { return }
        backdrop = environment.backdrop(self)
        restyle()
    }

    private func resolvePalette() {
        glassDecision =
            style == .glass && !embedded
            ? GlassPillPolicy.decide(
                materialAvailable: environment.materialAvailable(), reduceTransparency: environment.reduceTransparency(),
                backdrop: backdrop
            )
            : .solid(.materialUnavailable)
        palette = CardPalette.resolve(style: style, dark: isDark, glass: glassDecision)
    }

    private func restyle() {
        resolvePalette()
        if let state { render(state, typography: typography) }
    }

    /// Where a control's middle is, in this view's coordinates. For the click test.
    func center(of action: CardAction) -> CGPoint? {
        if showsHiFi, let view = hifi?.buttonViews[action] { return convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view) }
        guard let view = buttons.first(where: { $0.action == action })?.view else { return nil }
        return convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    var dismissCenter: CGPoint {
        if showsHiFi, let view = hifi?.closeView { return convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view) }
        return convert(CGPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), from: dismiss)
    }

    /// Every button's frame, in this view's coordinates, for hit tests.
    var buttonFrames: [CardAction: CGRect] {
        if showsHiFi, let hifi { return Dictionary(uniqueKeysWithValues: hifi.buttonViews.map { ($0.key, convert($0.value.bounds, from: $0.value)) }) }
        return Dictionary(uniqueKeysWithValues: buttons.map { ($0.action, convert($0.view.bounds, from: $0.view)) })
    }

    var dismissFrame: CGRect {
        if showsHiFi, let view = hifi?.closeView { return convert(view.bounds, from: view) }
        return convert(dismiss.bounds, from: dismiss)
    }

    /// Fills the card for `state` and returns the whole size the view needs: shadow margin included, unless embedded.
    @discardableResult
    func render(_ new: CardViewState, typography: Typography, countdownStart sharedStart: CFTimeInterval? = nil) -> CGSize {
        let isNewCard = state?.card != new.card
        state = new
        self.typography = typography
        if isNewCard { countdownStart = new.card.countdown == nil ? nil : (sharedStart ?? CACurrentMediaTime()) }
        let card = new.card
        let k = self.k
        hifiCanDraw = hifi.map { HiFiCardView.canRender(new.card, assets: $0.assets) } ?? true
        header.isHidden = showsHiFi
        dismiss.isHidden = showsHiFi
        hifi?.isHidden = !showsHiFi
        if showsHiFi { return renderHiFi(new) }

        let headerFont = typography.font(.header, scale: k)
        let bodyFont = typography.font(.body, scale: k)
        let buttonFont = typography.font(.button, scale: k)
        let numericFont = typography.font(.numeric, scale: k)

        header.textColor = palette.ink.withAlphaComponent(0.85)
        let headerString = NSAttributedString(
            string: card.header, attributes: [.font: headerFont, .foregroundColor: header.textColor ?? palette.ink]
        )
        header.attributedStringValue = headerString
        let headerHeight = Self.height(of: headerString, width: CardLayout.headerTextWidth(scale: k, showsDot: palette.showsDot))

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineBreakMode = .byWordWrapping
        bodyStyle.lineSpacing = max(0, round(bodyFont.pointSize * 1.38) - Typography.lineHeight(bodyFont))
        var transcriptString: NSAttributedString?
        if let text = card.transcript {
            transcriptString = NSAttributedString(
                string: text, attributes: [.font: bodyFont, .foregroundColor: palette.body, .paragraphStyle: bodyStyle]
            )
        } else if let pair = card.pair {
            transcriptString = Self.pairString(pair, palette: palette, bodyFont: bodyFont, emphasis: buttonFont, style: bodyStyle)
        }
        let accent = palette.accent(for: card.kind)
        dot.backgroundColor = accent.cgColor
        dot.shadowColor = accent.cgColor
        barFill.backgroundColor = accent.withAlphaComponent(0.6).cgColor
        let transcriptHeight = transcriptString.map { Self.height(of: $0, width: CardLayout.contentWidth(scale: k)) }
        let lineHeight = Typography.lineHeight(bodyFont) + max(0, round(bodyFont.pointSize * 1.38) - Typography.lineHeight(bodyFont))

        // Every label a button can show, so its width holds still while the label changes.
        var labels: [CardAction: [NSAttributedString]] = [:]
        for action in card.actions {
            labels[action] = Self.labels(for: action, in: new, primary: card.actions.first == action, palette: palette, buttonFont: buttonFont, numericFont: numericFont, remaining: card.countdown)
        }
        let layout = CardLayout.make(
            .init(
                headerTextHeight: headerHeight, headerLineHeight: Typography.lineHeight(headerFont),
                transcriptTextHeight: transcriptHeight, transcriptLineHeight: lineHeight,
                buttonLabelWidths: card.actions.map { action in (labels[action] ?? []).map { $0.size().width }.max() ?? 0 },
                hasCountdownBar: card.countdown != nil && !embedded, maxHeight: embedded ? maxFaceHeight : nil
            ), scale: k, showsDot: palette.showsDot)
        frames = layout

        let margin = embedded ? 0 : CardLayout.shadowMargin * k
        let panelSize = CGSize(width: layout.size.width + 2 * margin, height: layout.size.height + 2 * margin)
        setFrameSize(panelSize)
        let face = CGRect(x: margin, y: margin, width: layout.size.width, height: layout.size.height)
        let radius = CardLayout.cornerRadius * k
        let material = glassDecision.usesMaterial
        withoutActions {
            shadows.frame = CGRect(origin: .zero, size: panelSize)
            shadows.isHidden = embedded
            for (shadow, drop, blur) in [(ambient, 4 * k, 6 * k), (contact, 0.8 * k, 1 * k)] {
                shadow.frame = face
                shadow.cornerRadius = radius
                shadow.shadowRadius = blur
                shadow.shadowOffset = CGSize(width: 0, height: -drop)
                shadow.backgroundColor = material ? NSColor.clear.cgColor : palette.shadowFill.cgColor
                // An explicit path, so the glass card (clear background) still casts its shadow.
                shadow.shadowPath = CGPath(roundedRect: CGRect(origin: .zero, size: face.size), cornerWidth: radius, cornerHeight: radius, transform: nil)
            }
            if material {
                // Keep the shadow outside the card, so it doesn't darken the glass from behind.
                let mask = CAShapeLayer()
                mask.fillRule = .evenOdd
                let path = CGMutablePath()
                path.addRect(shadows.bounds)
                path.addRoundedRect(in: face, cornerWidth: radius, cornerHeight: radius)
                mask.path = path
                shadows.mask = mask
            } else {
                shadows.mask = nil
            }
            body.frame = face
            body.isHidden = embedded
            body.cornerRadius = radius
            body.backgroundColor = palette.bodyFill?.cgColor ?? NSColor.clear.cgColor
            body.borderWidth = palette.border == nil ? 0 : k
            body.borderColor = palette.border?.cgColor
            dot.isHidden = !palette.showsDot
            dot.cornerRadius = CardLayout.dot * k / 2
            dot.shadowRadius = 3 * k
        }
        content.frame = face
        glass.isHidden = !material || embedded
        if material {
            glass.frame = face
            glass.cornerRadius = radius
            if case .glass(.clear) = glassDecision {
                glass.style = .clear
                glass.tintColor = NSColor.white.withAlphaComponent(0.12)
            } else {
                glass.style = .regular
                glass.tintColor = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 22 / 255, alpha: 0.55)
            }
        }

        dot.frame = layout.dot
        header.frame = layout.header
        dismiss.frame = layout.dismiss
        dismiss.palette = palette
        dismiss.k = k

        if let transcript = layout.transcript, let transcriptString {
            scroll.isHidden = false
            scroll.frame = transcript
            scroll.hasVerticalScroller = layout.transcriptScrolls
            textView.frame = CGRect(x: 0, y: 0, width: transcript.width, height: transcriptHeight ?? transcript.height)
            textView.textStorage?.setAttributedString(transcriptString)
            if isNewCard { scroll.contentView.scroll(to: .zero) }
        } else {
            scroll.isHidden = true
        }

        let previousButtons = isNewCard ? [] : buttons
        var nextButtons: [(action: CardAction, view: CardButtonView)] = []
        for (index, action) in card.actions.enumerated() where index < layout.buttons.count {
            let view = previousButtons.first(where: { $0.action == action })?.view ?? CardButtonView(frame: .zero)
            view.frame = layout.buttons[index]
            view.palette = palette
            view.k = k
            view.isPrimary = index == 0
            view.isActive = !new.copied
            view.label = Self.labels(for: action, in: new, primary: index == 0, palette: palette, buttonFont: buttonFont, numericFont: numericFont, remaining: remaining)[0]
            view.onClick = { [weak self] in self?.onAction?(action) }
            if view.superview !== content { content.addSubview(view) }
            nextButtons.append((action, view))
        }
        for entry in buttons where !nextButtons.contains(where: { $0.view === entry.view }) { entry.view.removeFromSuperview() }
        buttons = nextButtons

        withoutActions {
            barClip.isHidden = layout.bar == nil
            barClip.cornerRadius = radius
            barClip.frame = face
            barFill.frame = CGRect(x: 0, y: 0, width: face.width, height: CardLayout.barHeight * k)
        }
        tick()
        needsDisplay = true
        return panelSize
    }

    /// The Hi-Fi window as the card: the classic pieces step aside, the shadow and size stay the card's own.
    private func renderHiFi(_ new: CardViewState) -> CGSize {
        guard let hifi else { return .zero }
        let k = self.k
        let size = hifi.render(new, scale: pillScale, readout: hifiReadout, remaining: remaining, fraction: barFraction)
        frames = nil
        let margin = CardLayout.shadowMargin * k
        let panelSize = CGSize(width: size.width + 2 * margin, height: size.height + 2 * margin)
        setFrameSize(panelSize)
        let face = CGRect(x: margin, y: margin, width: size.width, height: size.height)
        withoutActions {
            shadows.frame = CGRect(origin: .zero, size: panelSize)
            shadows.isHidden = false
            shadows.mask = nil
            for (shadow, drop, blur) in [(ambient, 4 * k, 6 * k), (contact, 0.8 * k, 1 * k)] {
                shadow.frame = face
                shadow.cornerRadius = 3 * k
                shadow.shadowRadius = blur
                shadow.shadowOffset = CGSize(width: 0, height: -drop)
                shadow.backgroundColor = NSColor(hex: 0x050506).cgColor
            }
            body.isHidden = true
            dot.isHidden = true
            scroll.isHidden = true
            barClip.isHidden = true
        }
        glass.isHidden = true
        content.frame = face
        hifi.frame = CGRect(origin: .zero, size: size)
        for entry in buttons { entry.view.removeFromSuperview() }
        buttons = []
        needsDisplay = true
        return panelSize
    }

    /// The countdown bar's fill now, nil without a countdown. Under Reduce Motion it steps once a second.
    private var barFraction: CGFloat? {
        guard let total = state?.card.countdown, let remaining else { return nil }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        return CardLayout.countdownFraction(remaining: reduce ? ceil(remaining) : remaining, total: total)
    }

    private var remaining: TimeInterval? {
        guard let total = state?.card.countdown, let start = countdownStart else { return nil }
        return max(0, total - (CACurrentMediaTime() - start))
    }

    /// What the pill's readout row shows for the card now. Nil when no card is rendered.
    var readout: CardReadout? {
        guard let card = state?.card else { return nil }
        let tone: CardReadout.Tone = card.kind.isQuestion ? .question : card.kind.isQuiet ? .quiet : .alert
        if let total = card.countdown, let remaining {
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let fraction = CardLayout.countdownFraction(remaining: reduce ? ceil(remaining) : remaining, total: total)
            return CardReadout(label: PillTimeline.timerText(seconds: Int(ceil(remaining))), isClock: true, tone: tone, progress: fraction)
        }
        return CardReadout(label: card.transcript == nil ? "" : "SAFE", isClock: false, tone: tone, progress: nil)
    }

    /// Re-draws the Undo countdown: the seconds on the button and the bar.
    func tick() {
        if showsHiFi {
            hifi?.tick(remaining: remaining, fraction: barFraction)
            return
        }
        guard let state, let layout = frames, let remaining, let total = state.card.countdown else { return }
        if !state.copied {
            for entry in buttons where entry.action == .undo {
                entry.view.label =
                    Self.labels(
                        for: .undo, in: state, primary: state.card.actions.first == .undo, palette: palette, buttonFont: typography.font(.button, scale: k),
                        numericFont: typography.font(.numeric, scale: k),
                        remaining: remaining
                    )[0]
                entry.view.needsDisplay = true
            }
        }
        if layout.bar != nil {
            // Under Reduce Motion the bar steps once a second instead of draining smoothly.
            let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            let shown = reduce ? ceil(remaining) : remaining
            let fraction = CardLayout.countdownFraction(remaining: shown, total: total)
            withoutActions { barFill.frame = CGRect(x: 0, y: 0, width: CardLayout.width * k * fraction, height: CardLayout.barHeight * k) }
        }
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// The label to show first, then every other the button might show (for sizing).
    private static func labels(
        for action: CardAction, in state: CardViewState, primary: Bool, palette: CardPalette, buttonFont: NSFont, numericFont: NSFont,
        remaining: TimeInterval?
    ) -> [NSAttributedString] {
        func text(_ string: String, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: buttonFont, .foregroundColor: color])
        }
        let color = primary ? palette.primaryText : palette.secondaryText
        if state.copied && action == .copy { return [text("Copied", color: color)] }
        if state.copied && action == .save { return [text("Saved", color: color)] }
        if state.copied && action == .forget { return [text("Forgotten", color: color)] }
        switch action {
        case .undo:
            func undo(_ seconds: String) -> NSAttributedString {
                let label = NSMutableAttributedString(string: "Undo ", attributes: [.font: buttonFont, .foregroundColor: color])
                label.append(NSAttributedString(string: seconds, attributes: [.font: numericFont, .foregroundColor: color]))
                return label
            }
            let total = state.card.countdown ?? DeliveryCard.undoWindow
            return [undo(CardLayout.countdownLabel(remaining: remaining ?? total)), undo(CardLayout.countdownLabel(remaining: total))]
        case .copy:
            return [text("Copy", color: color), text("Copied", color: color)]
        case .insert:
            return [text("Insert", color: color)]
        case .save:
            return [text("Save", color: color), text("Saved", color: color)]
        case .forget:
            return [text("Forget", color: color), text("Forgotten", color: color)]
        case .notNow:
            return [text("Not now", color: color)]
        case .keep:
            return [text("Keep", color: color)]
        case .recover:
            return [text("Recover", color: color)]
        case .discard:
            return [text("Discard", color: color)]
        case .openSoundSettings:
            return [text("Sound settings", color: color)]
        }
    }

    /// `heard → corrected` in the body face, the corrected form in the button face's heavier weight.
    private static func pairString(_ pair: SpellingPair, palette: CardPalette, bodyFont: NSFont, emphasis: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: palette.body, .paragraphStyle: style]
        let bold = NSFont(descriptor: emphasis.fontDescriptor, size: bodyFont.pointSize) ?? bodyFont
        let result = NSMutableAttributedString(string: "\(pair.heard) \u{2192} ", attributes: plain)
        result.append(
            NSAttributedString(
                string: pair.corrected,
                attributes: [
                    .font: bold, .foregroundColor: palette.emphasis, .paragraphStyle: style,
                ]))
        return result
    }

    private static func height(of string: NSAttributedString, width: CGFloat) -> CGFloat {
        let storage = NSTextStorage(attributedString: string)
        let container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        let manager = NSLayoutManager()
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return ceil(manager.usedRect(for: container).height)
    }
}

/// A plain flipped container, so the card's content lays out from its top left.
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
