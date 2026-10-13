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

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(
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
}

/// The 20 pt round dismiss control.
@MainActor
final class CardDismissView: CardControlView {
    override func draw(_ dirtyRect: NSRect) {
        let alpha: CGFloat = isPressed ? 0.42 : isHovered ? 0.30 : 0.16
        NSColor(white: 0.5, alpha: alpha).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let c = CGPoint(x: bounds.midX, y: bounds.midY), h: CGFloat = 3.2
        let cross = NSBezierPath()
        cross.move(to: CGPoint(x: c.x - h, y: c.y - h))
        cross.line(to: CGPoint(x: c.x + h, y: c.y + h))
        cross.move(to: CGPoint(x: c.x - h, y: c.y + h))
        cross.line(to: CGPoint(x: c.x + h, y: c.y - h))
        cross.lineWidth = 1.6
        cross.lineCapStyle = .round
        NSColor(white: 1, alpha: 0.85).setStroke()
        cross.stroke()
    }
}

/// A pill-shaped text button: the first of a card's buttons is the filled primary, the rest the quiet kind.
@MainActor
final class CardButtonView: CardControlView {
    var label = NSAttributedString()
    var isPrimary = true

    override func draw(_ dirtyRect: NSRect) {
        let scale: CGFloat = isPressed ? 0.97 : 1
        let rect = bounds.insetBy(dx: bounds.width * (1 - scale) / 2, dy: bounds.height * (1 - scale) / 2)
        let fill: NSColor
        if isPrimary {
            let base = CardPalette.ink
            fill = isPressed ? base.blended(withFraction: 0.18, of: .black) ?? base
                : isHovered ? base.blended(withFraction: 0.5, of: .white) ?? base : base
        } else {
            fill = NSColor(white: 0.5, alpha: isPressed ? 0.42 : isHovered ? 0.30 : 0.18)
        }
        fill.setFill()
        NSBezierPath(roundedRect: rect, xRadius: rect.height / 2, yRadius: rect.height / 2).fill()
        let size = label.size()
        label.draw(at: CGPoint(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2))
    }
}

enum CardPalette {
    static let ink = NSColor(hex: 0xF4F3E8)
    static let body = NSColor(hex: 0xF1F0E6)
    static let onInk = NSColor(hex: 0x1D1D1F)
    static let warn = NSColor(hex: 0xFF453A)

    /// The status dot and countdown bar: red for a delivery problem, the quiet ink for a question.
    static func accent(for kind: DeliveryCard.Kind) -> NSColor { kind.isOffer ? ink : warn }
}

/// The card: the dark surface, the reason line with its status dot, the transcript, the buttons and the dismiss
/// control, laid out by `CardLayout`. The view fills its panel, with the face inset by the shadow margin.
@MainActor
final class DeliveryCardView: NSView {
    var onAction: (@MainActor (CardAction) -> Void)?
    var onDismiss: (@MainActor () -> Void)?

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
    private var countdownStart: CFTimeInterval?
    private(set) var frames: CardLayout.Frames?
    /// The face size, without the shadow margin.
    var faceSize: CGSize { frames?.size ?? .zero }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        for (shadow, opacity, radius, drop) in [(ambient, Float(0.50), CGFloat(6), CGFloat(4)), (contact, 0.35, 1, 0.8)] {
            shadow.backgroundColor = ClassicPillView.fill.cgColor
            shadow.cornerRadius = CardLayout.cornerRadius
            shadow.cornerCurve = .continuous
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = opacity
            shadow.shadowRadius = radius
            shadow.shadowOffset = CGSize(width: 0, height: -drop)
            layer?.addSublayer(shadow)
        }
        body.backgroundColor = ClassicPillView.fill.withAlphaComponent(0.96).cgColor
        body.cornerRadius = CardLayout.cornerRadius
        body.cornerCurve = .continuous
        body.borderWidth = 1
        body.borderColor = ClassicPillView.stroke.cgColor
        layer?.addSublayer(body)

        addSubview(content)
        dot.cornerRadius = CardLayout.dot / 2
        dot.backgroundColor = CardPalette.warn.cgColor
        dot.shadowColor = CardPalette.warn.cgColor
        dot.shadowOpacity = 0.9
        dot.shadowRadius = 3
        dot.shadowOffset = .zero
        content.wantsLayer = true
        content.layer?.addSublayer(dot)

        header.isSelectable = false
        header.maximumNumberOfLines = 0
        header.lineBreakMode = .byWordWrapping
        header.textColor = CardPalette.ink.withAlphaComponent(0.85)
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
        barClip.cornerRadius = CardLayout.cornerRadius
        barClip.cornerCurve = .continuous
        barClip.masksToBounds = true
        barFill.backgroundColor = CardPalette.warn.withAlphaComponent(0.6).cgColor
        barClip.addSublayer(barFill)
        layer?.addSublayer(barClip)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    /// Where a control's middle is, in this view's coordinates. For the click test.
    func center(of action: CardAction) -> CGPoint? {
        guard let view = buttons.first(where: { $0.action == action })?.view else { return nil }
        return convert(CGPoint(x: view.bounds.midX, y: view.bounds.midY), from: view)
    }

    var dismissCenter: CGPoint { convert(CGPoint(x: dismiss.bounds.midX, y: dismiss.bounds.midY), from: dismiss) }

    /// Fills the card for `state` and returns the whole size the view needs, shadow margin included.
    @discardableResult
    func render(_ new: CardViewState, typography: Typography) -> CGSize {
        let isNewCard = state?.card != new.card
        state = new
        self.typography = typography
        if isNewCard { countdownStart = new.card.countdown == nil ? nil : CACurrentMediaTime() }
        let card = new.card

        let headerFont = typography.font(.header)
        let bodyFont = typography.font(.body)
        let buttonFont = typography.font(.button)
        let numericFont = typography.font(.numeric)

        let headerString = NSAttributedString(
            string: card.header, attributes: [.font: headerFont, .foregroundColor: header.textColor ?? CardPalette.ink]
        )
        header.attributedStringValue = headerString
        let headerHeight = Self.height(of: headerString, width: CardLayout.headerTextWidth)

        let bodyStyle = NSMutableParagraphStyle()
        bodyStyle.lineBreakMode = .byWordWrapping
        bodyStyle.lineSpacing = max(0, round(bodyFont.pointSize * 1.38) - Typography.lineHeight(bodyFont))
        var transcriptString: NSAttributedString?
        if let text = card.transcript {
            transcriptString = NSAttributedString(
                string: text, attributes: [.font: bodyFont, .foregroundColor: CardPalette.body, .paragraphStyle: bodyStyle]
            )
        } else if let pair = card.pair {
            transcriptString = Self.pairString(pair, bodyFont: bodyFont, emphasis: buttonFont, style: bodyStyle)
        }
        let accent = CardPalette.accent(for: card.kind)
        dot.backgroundColor = accent.cgColor
        dot.shadowColor = accent.cgColor
        barFill.backgroundColor = accent.withAlphaComponent(0.6).cgColor
        let transcriptHeight = transcriptString.map { Self.height(of: $0, width: CardLayout.contentWidth) }
        let lineHeight = Typography.lineHeight(bodyFont) + max(0, round(bodyFont.pointSize * 1.38) - Typography.lineHeight(bodyFont))

        // Every label a button can show, so its width holds still while the label changes.
        var labels: [CardAction: [NSAttributedString]] = [:]
        for action in card.actions {
            labels[action] = Self.labels(for: action, in: new, primary: card.actions.first == action, buttonFont: buttonFont, numericFont: numericFont, remaining: card.countdown)
        }
        let layout = CardLayout.make(.init(
            headerTextHeight: headerHeight, headerLineHeight: Typography.lineHeight(headerFont),
            transcriptTextHeight: transcriptHeight, transcriptLineHeight: lineHeight,
            buttonLabelWidths: card.actions.map { action in (labels[action] ?? []).map { $0.size().width }.max() ?? 0 },
            hasCountdownBar: card.countdown != nil
        ))
        frames = layout

        let margin = CardLayout.shadowMargin
        let panelSize = CGSize(width: layout.size.width + 2 * margin, height: layout.size.height + 2 * margin)
        setFrameSize(panelSize)
        let face = CGRect(x: margin, y: margin, width: layout.size.width, height: layout.size.height)
        ambient.frame = face
        contact.frame = face
        body.frame = face
        content.frame = face

        dot.frame = layout.dot
        header.frame = layout.header
        dismiss.frame = layout.dismiss

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

        for entry in buttons { entry.view.removeFromSuperview() }
        buttons = []
        for (index, action) in card.actions.enumerated() where index < layout.buttons.count {
            let view = CardButtonView(frame: layout.buttons[index])
            view.isPrimary = index == 0
            view.isActive = !new.copied
            view.label = Self.labels(for: action, in: new, primary: index == 0, buttonFont: buttonFont, numericFont: numericFont, remaining: remaining)[0]
            view.onClick = { [weak self] in self?.onAction?(action) }
            content.addSubview(view)
            buttons.append((action, view))
        }

        barClip.isHidden = layout.bar == nil
        barClip.frame = face
        withoutActions { barFill.frame = CGRect(x: 0, y: 0, width: face.width, height: CardLayout.barHeight) }
        tick()
        needsDisplay = true
        return panelSize
    }

    private var remaining: TimeInterval? {
        guard let total = state?.card.countdown, let start = countdownStart else { return nil }
        return max(0, total - (CACurrentMediaTime() - start))
    }

    /// Re-draws the Undo countdown: the seconds on the button and the bar.
    func tick() {
        guard let state, let layout = frames, let remaining, let total = state.card.countdown else { return }
        if !state.copied {
            for entry in buttons where entry.action == .undo {
                entry.view.label = Self.labels(
                    for: .undo, in: state, primary: state.card.actions.first == .undo, buttonFont: typography.font(.button), numericFont: typography.font(.numeric),
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
            withoutActions { barFill.frame = CGRect(x: 0, y: 0, width: CardLayout.width * fraction, height: CardLayout.barHeight) }
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
        for action: CardAction, in state: CardViewState, primary: Bool, buttonFont: NSFont, numericFont: NSFont,
        remaining: TimeInterval?
    ) -> [NSAttributedString] {
        func text(_ string: String, color: NSColor) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: buttonFont, .foregroundColor: color])
        }
        let color = primary ? CardPalette.onInk : CardPalette.body
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
        }
    }

    /// `heard → corrected` in the body face, the corrected form in the button face's heavier weight.
    private static func pairString(_ pair: SpellingPair, bodyFont: NSFont, emphasis: NSFont, style: NSParagraphStyle) -> NSAttributedString {
        let plain: [NSAttributedString.Key: Any] = [.font: bodyFont, .foregroundColor: CardPalette.body, .paragraphStyle: style]
        let bold = NSFont(descriptor: emphasis.fontDescriptor, size: bodyFont.pointSize) ?? bodyFont
        let result = NSMutableAttributedString(string: "\(pair.heard) \u{2192} ", attributes: plain)
        result.append(NSAttributedString(string: pair.corrected, attributes: [
            .font: bold, .foregroundColor: CardPalette.ink, .paragraphStyle: style,
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
