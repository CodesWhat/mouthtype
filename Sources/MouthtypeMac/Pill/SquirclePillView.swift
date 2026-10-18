import AppKit
import QuartzCore

/// A shape filled with a vertical gradient: the gradient layer spans the whole container and a path mask cuts it to
/// the shape, so a width change animates the mask path and the fill follows.
@MainActor
private final class GradientShape {
    let layer = CAGradientLayer()
    let mask = CAShapeLayer()

    init() {
        mask.fillColor = NSColor.black.cgColor
        layer.mask = mask
    }

    /// Colours run from `top` to `bottom` between the rect's top and bottom edges, in `container`.
    func setColors(_ colors: [NSColor]) {
        layer.colors = colors.map(\.cgColor)
    }

    func setSpan(top: CGFloat, bottom: CGFloat, in container: CGRect) {
        layer.frame = container
        mask.frame = layer.bounds
        layer.startPoint = CGPoint(x: 0.5, y: top / max(1, container.height))
        layer.endPoint = CGPoint(x: 0.5, y: bottom / max(1, container.height))
    }
}

/// The Matrix and Minimal pills: a 30 pt squircle with an indicator, a meter, a REC label or a clock, and squircle
/// controls once locked. Matrix reads the level as a 13 x 7 amber dot matrix, Minimal as ten plain bars, and
/// everything else is shared. Core Animation layers throughout: the meter is two shape layers whose paths change only
/// when a column's lit rows do, the REC lamp breathes with a repeating layer animation, and widths are spring-animated
/// path changes. Under Reduce Motion the springs and the breathing go, and content cross-fades instead.
@MainActor
class SquirclePillView: NSView, PillSkinView {
    private static let travel: CGFloat = 5
    private static let appearScale: CGFloat = 0.9
    static let detailAlpha: CGFloat = 0.62

    private struct Disc {
        let group = CALayer()
        let shape = CAShapeLayer()
        let glyph = CAShapeLayer()
    }

    /// How the indicator lamp moves, for tests and for choosing the animation.
    enum LampMotion: Equatable {
        case steady, breathing, pulsing, flashing
    }

    let flavor: SquircleFlavor
    let pillScale: PillScale
    private let metrics: MatrixPillLayout.Metrics
    private var k: CGFloat { metrics.factor }

    private let container = CALayer()
    private let ambient = CAShapeLayer()
    private let contact = CAShapeLayer()
    private let bodyShape = GradientShape()
    private let highlightShape = GradientShape()
    private let rim = CAShapeLayer()
    private let windowShape = GradientShape()
    private let windowEdge = CAShapeLayer()
    /// Everything left-anchored lives here, so the group's origin follows the capsule's left edge as it springs.
    private let content = CALayer()
    private let lampGroup = CALayer()
    private let lamp = CAShapeLayer()
    private let lips = CALayer()
    private let meterGroup = CALayer()
    private let ghost = CAShapeLayer()
    private let lit = CAShapeLayer()
    private let idle = CAShapeLayer()
    private let recLabel = CATextLayer()
    private let clockLabel = CATextLayer()
    private let processingGroup = CALayer()
    private let processingDots = (0..<3).map { _ in CAShapeLayer() }
    /// Clips the message to the room inside the capsule, so a message too long for the panel scrolls rather than spills.
    private let textClip = CALayer()
    private let textGroup = CALayer()
    private var lineLayers: [CATextLayer] = []
    private let discs: [PillControl: Disc] = [.cancel: Disc(), .stop: Disc()]

    private var palette: SquirclePalette
    private var scale: CGFloat = 2
    private var mode = MatrixPillLayout.Mode.hold
    private var width: CGFloat
    private var height: CGFloat
    private var presented = false
    /// When the fade-out in flight began, how long it takes and the opacity it started from; nil when none is.
    private var fadeOut: (start: CFTimeInterval, duration: TimeInterval, from: Float)?
    /// The opacity the last `appear` began from: 0 for a pill coming up from nothing, above 0 for one turned round mid
    /// fade-out. For tests.
    private(set) var appearStartOpacity: Float = 0
    /// A card folded into the pill: its width, the height above the readout row, and what the row says about it.
    private var cardWidth: CGFloat?
    private var cardHeight: CGFloat = 0
    private var cardReadout: CardReadout?
    /// The height of the pill's own row: 30 pt, or the message block's height.
    private var rowHeight: CGFloat
    private let rowClip = CALayer()
    private let rowClipMask = CAShapeLayer()
    private let rowShade = CALayer()
    private let rowRule = CALayer()
    private let cardBar = CALayer()
    private(set) var typography = Typography.current()
    private var message: PillMessage?
    private var messageOverRecording = false
    /// How far the text has scrolled up, 0 at the start and `block.overflow` at the end.
    private var messageScroll: CGFloat = 0
    private var block: ClassicPillLayout.MessageBlock
    private var halfRows: [Int]
    private var clockText = "0:00"
    private var dotsLit = -1
    private var hovered: PillControl?
    private var pressed: PillControl?
    private(set) var isLocked = false
    private(set) var lampMotion = LampMotion.steady
    /// Replaces the system Reduce Motion setting; tests set it.
    var reduceMotionOverride: Bool?
    private var reduceMotionObserver: NSObjectProtocol?
    /// The Reduce Motion value the lamp was last set up for.
    private var lampReducedMotion = false

    var messageLines: [ClassicPillLayout.MessageLine] { block.lines }
    var messageSize: CGSize { CGSize(width: block.width, height: block.height) }
    /// How far a message too tall for the panel has to scroll, 0 when it all fits.
    var messageScrollDistance: Int { Int(block.overflow.rounded(.up)) }
    /// The message's lines in the capsule's coordinates as drawn now, scrolled.
    var messageLineFrames: [CGRect] {
        lineLayers.prefix(block.lines.count).map { $0.frame.offsetBy(dx: textGroup.position.x, dy: textGroup.position.y) }
    }
    /// Where the message can be seen, in the capsule's coordinates.
    var messageViewport: CGRect { textClip.bounds }
    /// The body's gradient, top to bottom. A Minimal card on a light desktop is lighter than the pill, per the spec.
    var bodyColours: [NSColor] {
        if cardWidth != nil, flavor == .minimal, !isDark { return [palette.bodyTop, SquirclePalette.lightCardBottom] }
        return [palette.bodyTop, palette.bodyBottom]
    }
    var usesWindow: Bool { palette.window != nil }
    var resolvedPalette: SquirclePalette { palette }
    var litHalfRows: [Int] { halfRows }
    var lampAnimation: CAAnimation? { lamp.animation(forKey: "motion") }
    var showsClock: Bool { clockLabel.opacity > 0.5 }
    var showsRecLabel: Bool { recLabel.opacity > 0.5 }
    var clockString: String { clockText }
    var lampOpacity: Float { lamp.opacity }
    var meterLayers: (ghost: CAShapeLayer, lit: CAShapeLayer, idle: CAShapeLayer) { (ghost, lit, idle) }
    /// The spring on the body, nil when it is not moving.
    var widthAnimation: CAAnimation? { bodyShape.mask.animation(forKey: "path") }
    var capsuleRect: CGRect { capsule(width: width, height: height) }
    /// The pill's own row, at the bottom of the capsule; the whole capsule unless a card is folded in.
    var rowRect: CGRect {
        let rect = capsuleRect
        return CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rowHeight)
    }

    var growsIntoCard: Bool { true }
    var grownFrame: CGRect? { cardWidth == nil ? nil : capsuleRect }
    /// Where the card's content goes: the capsule less its row, in this view's coordinates.
    var cardFrame: CGRect? {
        guard cardWidth != nil else { return nil }
        let rect = capsuleRect
        return CGRect(x: rect.minX, y: rect.maxY - cardHeight, width: rect.width, height: cardHeight)
    }
    var readoutLabelMinX: CGFloat { (mode.readout?.isClock == true ? clockLabel : recLabel).frame.minX }
    var readoutLabel: String? { cardReadout?.label }
    var cardProgress: CGFloat? { cardReadout?.progress }
    var lampTone: CardReadout.Tone? { mode.readout?.tone }

    var controlFrames: [PillControl: CGRect] {
        guard isLocked, mode == .locked else { return [:] }
        return MatrixPillLayout.controlFrames(capsule: rowRect, metrics: metrics)
    }

    private var isDark: Bool {
        effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    private var reduceMotion: Bool {
        reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    private var isBars: Bool { flavor == .minimal }

    init(frame: NSRect, size: PillScale, flavor: SquircleFlavor) {
        self.flavor = flavor
        pillScale = size
        metrics = MatrixPillLayout.Metrics(size)
        width = metrics.heldWidth
        height = metrics.height
        rowHeight = metrics.height
        palette = SquirclePalette.resolve(flavor, dark: true)
        block = ClassicPillLayout.MessageBlock(width: 0, height: metrics.height, lines: [])
        halfRows = [Int](repeating: 0, count: flavor == .minimal ? MatrixPillLayout.barCount : MatrixPillLayout.columns)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        palette = SquirclePalette.resolve(flavor, dark: isDark)

        container.frame = bounds
        container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.opacity = 0
        layer?.addSublayer(container)

        for (shadow, drop, radius) in [(ambient, 4 * k, 6 * k), (contact, 0.8 * k, 1 * k)] {
            shadow.fillColor = nil
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowRadius = radius
            shadow.shadowOffset = CGSize(width: 0, height: -drop)
            container.addSublayer(shadow)
        }
        container.addSublayer(bodyShape.layer)
        container.addSublayer(highlightShape.layer)
        rowClip.mask = rowClipMask
        rowClipMask.fillColor = NSColor.black.cgColor
        for layer in [rowShade, rowRule, cardBar] { layer.anchorPoint = .zero; rowClip.addSublayer(layer) }
        rowClip.isHidden = true
        container.addSublayer(rowClip)
        rim.fillColor = nil
        container.addSublayer(rim)
        container.addSublayer(windowShape.layer)
        windowEdge.fillColor = nil
        container.addSublayer(windowEdge)

        content.anchorPoint = .zero
        container.addSublayer(content)
        lampGroup.addSublayer(lamp)
        lamp.path = CGPath(ellipseIn: CGRect(x: -3 * k, y: -3 * k, width: 6 * k, height: 6 * k), transform: nil)
        lamp.shadowOffset = .zero
        lamp.shadowRadius = 2 * k
        content.addSublayer(lampGroup)
        lips.bounds = CGRect(x: 0, y: 0, width: CGFloat(LipsSprite.size) * k, height: CGFloat(LipsSprite.size) * k)
        lips.magnificationFilter = .nearest
        lips.minificationFilter = .nearest
        lips.opacity = 0
        content.addSublayer(lips)
        if flavor == .matrix { ghost.path = Self.ghostPath(metrics: metrics) }
        meterGroup.addSublayer(ghost)
        meterGroup.addSublayer(idle)
        meterGroup.addSublayer(lit)
        idle.opacity = Float(MatrixPillLayout.idleAlpha)
        content.addSublayer(meterGroup)
        for label in [recLabel, clockLabel] {
            label.alignmentMode = .left
            label.truncationMode = .none
            label.isWrapped = false
            label.opacity = 0
            content.addSublayer(label)
        }
        for dot in processingDots {
            dot.path = CGPath(ellipseIn: CGRect(x: -1.5 * k, y: -1.5 * k, width: 3 * k, height: 3 * k), transform: nil)
            dot.opacity = 0.18
            processingGroup.addSublayer(dot)
        }
        processingGroup.opacity = 0
        content.addSublayer(processingGroup)
        textGroup.opacity = 0
        textClip.anchorPoint = .zero
        textClip.masksToBounds = true
        textClip.addSublayer(textGroup)
        content.addSublayer(textClip)

        for (control, disc) in discs {
            disc.group.bounds = CGRect(origin: .zero, size: CGSize(width: metrics.controlSize, height: metrics.controlSize))
            disc.group.opacity = 0
            disc.shape.path = MatrixPillLayout.squirclePath(disc.group.bounds, reference: metrics.controlSize)
            disc.glyph.path = Self.glyphPath(stop: control == .stop, in: disc.group.bounds, k: k)
            disc.glyph.lineWidth = 1.5 * k
            disc.glyph.lineCap = .round
            disc.group.addSublayer(disc.shape)
            disc.group.addSublayer(disc.glyph)
            container.addSublayer(disc.group)
        }
        applyPalette()
        applyScale()
        relayout()
        reduceMotionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reduceMotionMayHaveChanged() } }
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let reduceMotionObserver { NSWorkspace.shared.notificationCenter.removeObserver(reduceMotionObserver) }
    }

    /// Reduce Motion was switched in System Settings: the lamp stops or starts at once instead of at the next state.
    func reduceMotionMayHaveChanged() {
        guard reduceMotion != lampReducedMotion else { return }
        updateLampMotion()
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyScale()
        relayout()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        applyScale()
        relayout()
    }

    override func layout() {
        super.layout()
        relayout()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        refreshAppearance()
    }

    private func refreshAppearance() {
        let next = SquirclePalette.resolve(flavor, dark: isDark)
        palette = next
        applyPalette()
        // Only colours change with the appearance, so the capsule is left where it is, mid-spring if it is moving.
        layoutLabels()
        layoutText()
    }

    // MARK: Colours and fonts

    private func applyPalette() {
        let p = palette
        PillMotion.withoutActions {
            ambient.shadowOpacity = p.ambientShadow
            contact.shadowOpacity = p.contactShadow
            bodyShape.setColors(bodyColours)
            highlightShape.setColors([p.highlight, p.highlight.withAlphaComponent(0)])
            rim.strokeColor = p.hairline.cgColor
            rim.lineWidth = max(0.5 * k, 1 / scale)
            if let window = p.window {
                windowShape.setColors([window.top, window.bottom])
                windowShape.layer.isHidden = false
                windowEdge.isHidden = false
                windowEdge.strokeColor = NSColor.white.withAlphaComponent(0.7).cgColor
                windowEdge.lineWidth = max(0.5 * k, 1 / scale)
            } else {
                windowShape.layer.isHidden = true
                windowEdge.isHidden = true
            }
            lamp.shadowColor = p.rec.cgColor
            lamp.shadowOpacity = isBars ? 0 : 1
            ghost.fillColor = p.ink.withAlphaComponent(p.ghostAlpha).cgColor
            ghost.isHidden = isBars
            for layer in [lit, idle] {
                layer.fillColor = p.ink.cgColor
                layer.shadowColor = p.glow?.cgColor
                layer.shadowOpacity = p.glow == nil ? 0 : 0.9
                layer.shadowRadius = 2.4 * k
                layer.shadowOffset = .zero
            }
            for dot in processingDots { dot.fillColor = p.ink.cgColor }
            lips.contents = LipsSprite.image(color: p.text)
            for (control, disc) in discs {
                disc.shape.fillColor = discFill(control)
                disc.glyph.fillColor = control == .stop ? p.finishGlyph.cgColor : nil
                disc.glyph.strokeColor = control == .stop ? nil : p.cancelGlyph.cgColor
            }
        }
        applyLampColour()
    }

    private func recFont() -> NSFont {
        switch flavor {
        case .matrix:
            NSFont(name: FontRegistry.monoName, size: 9 * k) ?? .monospacedSystemFont(ofSize: 9 * k, weight: .medium)
        case .minimal:
            .systemFont(ofSize: 9.5 * k, weight: .semibold)
        }
    }

    private func clockFont() -> NSFont {
        switch flavor {
        case .matrix:
            NSFont(name: FontRegistry.monoName, size: 11 * k) ?? .monospacedSystemFont(ofSize: 11 * k, weight: .medium)
        case .minimal:
            .monospacedDigitSystemFont(ofSize: 12 * k, weight: .medium)
        }
    }

    private func messageFont(isDetail: Bool) -> NSFont {
        switch flavor {
        case .matrix: typography.font(isDetail ? .pillDetail : .pillMessage, scale: k)
        case .minimal: .systemFont(ofSize: (isDetail ? 11.5 : 13) * k, weight: isDetail ? .regular : .semibold)
        }
    }

    // MARK: Geometry

    private func applyScale() {
        scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in allLayers { layer.contentsScale = scale }
        container.contentsScale = scale
        PillMotion.withoutActions { rim.lineWidth = max(0.5 * k, 1 / scale) }
    }

    private var allLayers: [CALayer] {
        [ambient, contact, bodyShape.mask, highlightShape.mask, rim, windowShape.mask, windowEdge, lamp, ghost, lit, idle,
         recLabel, clockLabel, textClip, textGroup, lips] + lineLayers + processingDots + discs.values.flatMap { [$0.group, $0.shape, $0.glyph] }
    }

    private func capsule(width: CGFloat, height: CGFloat? = nil) -> CGRect {
        MatrixPillLayout.capsuleFrame(
            width: width, height: height ?? self.height, bounds: bounds.size, bottomMargin: PillGeometry.verticalMargin, scale: scale
        )
    }

    private func relayout() {
        place(width: width, height: height, timing: .none)
        layoutContent()
    }

    private func place(width newWidth: CGFloat, height newHeight: CGFloat? = nil, timing: PillMotion.Timing) {
        let newHeight = newHeight ?? metrics.height
        width = newWidth
        height = newHeight
        let rect = capsule(width: newWidth, height: newHeight)
        let row = CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: rowHeight)
        // A card's corner is its own 16 pt; the pill keeps the 30 pt pill's.
        let reference = cardWidth == nil ? metrics.height : MatrixPillLayout.cornerReference(radius: CardLayout.cornerRadius * k)
        let path = MatrixPillLayout.squirclePath(rect, reference: reference)
        let bounds = container.bounds
        PillMotion.withoutActions {
            bodyShape.setSpan(top: rect.maxY, bottom: rect.minY, in: bounds)
            highlightShape.setSpan(top: rect.maxY, bottom: rect.maxY - 1.5 * k, in: bounds)
            windowShape.setSpan(top: row.maxY - metrics.windowInset, bottom: row.minY + metrics.windowInset, in: bounds)
            rowClip.frame = bounds
            rowClipMask.frame = rowClip.bounds
        }
        PillMotion.set(bodyShape.mask, "path", path, timing)
        PillMotion.set(highlightShape.mask, "path", path, timing)
        PillMotion.set(rowClipMask, "path", path, timing)
        PillMotion.set(ambient, "shadowPath", path, timing)
        PillMotion.set(contact, "shadowPath", path, timing)
        PillMotion.set(rim, "path", MatrixPillLayout.squirclePath(rect.insetBy(dx: 0.25 * k, dy: 0.25 * k), reference: reference), timing)
        let window = cardWidth == nil
            ? MatrixPillLayout.windowFrame(capsule: rect, locked: newWidth == metrics.lockedWidth, metrics: metrics)
            : MatrixPillLayout.windowFrame(capsule: row, locked: !mode.isMessage, metrics: metrics).offsetBy(dx: rowShift, dy: 0)
        let windowPath = MatrixPillLayout.squirclePath(window, reference: window.height)
        PillMotion.set(windowShape.mask, "path", windowPath, timing)
        PillMotion.set(windowEdge, "path", windowPath, timing)
        PillMotion.set(content, "position", NSValue(point: rect.origin), timing)
        PillMotion.withoutActions { content.bounds = CGRect(origin: .zero, size: rect.size) }
        placeRowChrome(rect: rect, timing: timing)
        // Controls travel with the capsule's right end while hidden too, so they fade in where they will sit.
        let frames = MatrixPillLayout.controlFrames(capsule: row, metrics: metrics)
        for (control, disc) in discs {
            guard let frame = frames[control] else { continue }
            PillMotion.set(disc.group, "position", NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), timing)
        }
    }

    /// The row's backing, the rule above it and the countdown bar, which only a folded card has.
    private func placeRowChrome(rect: CGRect, timing: PillMotion.Timing) {
        PillMotion.withoutActions { rowClip.isHidden = cardWidth == nil }
        let origin = NSValue(point: rect.origin)
        PillMotion.set(rowShade, "position", origin, timing)
        PillMotion.set(rowShade, "bounds", NSValue(rect: CGRect(x: 0, y: 0, width: rect.width, height: rowHeight)), timing)
        PillMotion.set(rowRule, "position", NSValue(point: CGPoint(x: rect.minX, y: rect.minY + rowHeight)), timing)
        PillMotion.set(rowRule, "bounds", NSValue(rect: CGRect(x: 0, y: 0, width: rect.width, height: 0.5 * k)), timing)
        PillMotion.set(cardBar, "position", origin, timing)
        applyCardChrome()
    }

    private var goodColor: NSColor { flavor == .minimal && !isDark ? NSColor(hex: 0x315B54) : palette.ink }

    private func toneColor(_ tone: CardReadout.Tone) -> NSColor {
        switch tone {
        case .alert: palette.error
        case .quiet: goodColor
        case .question: palette.ink
        }
    }

    /// Colours and the bar's fill for the card's readout. The bar is 3 pt along the capsule's bottom edge.
    private func applyCardChrome() {
        PillMotion.withoutActions {
            let hasWindow = palette.window != nil
            rowShade.backgroundColor = (isDark ? NSColor.black.withAlphaComponent(0.25) : NSColor.black.withAlphaComponent(hasWindow ? 0 : 0.04)).cgColor
            rowRule.backgroundColor = (isDark ? NSColor.white.withAlphaComponent(0.12) : NSColor.black.withAlphaComponent(0.08)).cgColor
            if let readout = cardReadout, let progress = readout.progress {
                cardBar.isHidden = false
                cardBar.backgroundColor = toneColor(readout.tone).withAlphaComponent(0.7).cgColor
                cardBar.bounds = CGRect(x: 0, y: 0, width: capsuleRect.width * min(1, max(0, progress)), height: 3 * k)
            } else {
                cardBar.isHidden = true
            }
        }
    }

    /// Where everything inside the content group sits, in the capsule's own coordinates (origin at its bottom left).
    private func layoutContent() {
        let midY = rowHeight / 2
        PillMotion.withoutActions {
            // The first text line's middle, so a wrapped message keeps its indicator beside the headline.
            let indicatorY = mode.isMessage && !block.lines.isEmpty ? midY - block.lines[0].centerOffset - block.overflow / 2 : midY
            lampGroup.position = CGPoint(x: metrics.indicatorCentre + rowShift, y: indicatorY)
            lips.position = CGPoint(x: metrics.indicatorCentre + rowShift, y: midY)
            for (i, dot) in processingDots.enumerated() {
                dot.position = CGPoint(x: metrics.labelX + (1.5 + 6 * CGFloat(i)) * k, y: midY)
            }
        }
        rebuildMeter()
        layoutLabels()
        layoutText()
    }

    /// The readout group's right edge, in the capsule's coordinates before any shift. A clock is held to its slot so the
    /// group doesn't wander as the digits change; a label is measured; no label ends the group at the meter.
    private func readoutRight(_ readout: CardReadout) -> CGFloat {
        if readout.isClock { return metrics.labelX + metrics.clockSlot }
        guard !readout.label.isEmpty else { return metrics.meterX + metrics.meterWidth }
        return metrics.labelX + labelString(readout.label, font: recFont(), color: palette.ink).size().width
    }

    /// How far the readout group (lamp, meter and label) moves right to sit in the middle of a grown card's row. Only
    /// the card's own readout is centred; a recording or a message under the card keeps the pill's usual slots.
    private var rowShift: CGFloat {
        guard let cardWidth, let readout = mode.readout else { return 0 }
        let width = max(cardWidth, MatrixPillLayout.capsuleWidth(mode, metrics: metrics))
        let left = metrics.padLeft
        return max(0, ClassicPillLayout.snap((width - (readoutRight(readout) - left)) / 2 - left, scale: scale))
    }

    /// The readout group's left and right edges in the capsule's coordinates as laid out now, nil outside a grown card's
    /// readout row. For tests.
    var readoutGroupExtent: (minX: CGFloat, maxX: CGFloat)? {
        guard cardWidth != nil, let readout = mode.readout else { return nil }
        return (metrics.padLeft + rowShift, readoutRight(readout) + rowShift)
    }

    private func textFrame(font: NSFont, x: CGFloat, width: CGFloat, midY: CGFloat) -> CGRect {
        let baseline = midY - font.capHeight / 2
        return CGRect(
            x: x, y: ClassicPillLayout.snap(baseline + font.descender, scale: scale), width: width, height: Typography.lineHeight(font)
        )
    }

    private func labelString(_ string: String, font: NSFont, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color, .kern: 0.9 * k])
    }

    /// "REC", or the card's short label when the row belongs to a card.
    private var recText: String {
        if let readout = mode.readout, !readout.isClock { return readout.label }
        return "REC"
    }

    private var shownClock: String {
        if let readout = mode.readout, readout.isClock { return readout.label }
        return clockText
    }

    private func layoutLabels() {
        let midY = rowHeight / 2
        let rec = recFont(), clock = clockFont()
        let recColor = isBars ? palette.ink.withAlphaComponent(0.9) : palette.ink
        PillMotion.withoutActions {
            recLabel.string = labelString(recText, font: rec, color: recColor)
            // A card's label ("SAFE") is a letter longer than REC, and the folded pill has the room.
            let recWidth = mode.readout == nil ? metrics.recSlot : metrics.recSlot + 10 * k
            recLabel.frame = textFrame(font: rec, x: metrics.labelX + rowShift, width: recWidth, midY: midY)
            clockLabel.string = NSAttributedString(
                string: shownClock, attributes: [.font: clock, .foregroundColor: palette.ink]
            )
            clockLabel.frame = textFrame(font: clock, x: metrics.labelX + rowShift, width: metrics.clockSlot, midY: midY)
        }
    }

    private func layoutText() {
        while lineLayers.count < block.lines.count {
            let layer = CATextLayer()
            layer.alignmentMode = .left
            layer.truncationMode = .none
            layer.isWrapped = false
            layer.contentsScale = scale
            textGroup.addSublayer(layer)
            lineLayers.append(layer)
        }
        let isError = message?.isError == true
        PillMotion.withoutActions {
            // A capped message starts with its first line at the top of the room and scrolls up from there.
            let pad = block.overflow > 0 ? metrics.messageVerticalPadding : 0
            let viewport = CGRect(x: 0, y: pad, width: width, height: max(0, height - 2 * pad))
            textClip.bounds = viewport
            textClip.position = viewport.origin
            textGroup.position = CGPoint(x: 0, y: messageScroll - block.overflow / 2)
            for (index, layer) in lineLayers.enumerated() {
                guard index < block.lines.count else {
                    layer.isHidden = true
                    continue
                }
                let line = block.lines[index]
                let font = messageFont(isDetail: line.isDetail)
                let color = line.isDetail ? palette.text.withAlphaComponent(Self.detailAlpha) : (isError ? palette.error : palette.text)
                layer.isHidden = false
                layer.string = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color])
                layer.frame = textFrame(
                    font: font, x: metrics.textX, width: max(0, width - metrics.textX - metrics.padRight), midY: rowHeight / 2 - line.centerOffset
                )
            }
        }
    }

    // MARK: Meter

    private func rebuildMeter() {
        let midY = rowHeight / 2
        let x = metrics.meterX + rowShift
        let litPath = CGMutablePath(), idlePath = CGMutablePath()
        if isBars {
            for (i, n) in halfRows.enumerated() {
                let frame = MatrixPillLayout.barFrame(index: i, halfRows: n, x: x, midY: midY, metrics: metrics)
                let corner = metrics.barWidth / 2
                (n > 0 ? litPath : idlePath).addRoundedRect(in: frame, cornerWidth: corner, cornerHeight: corner)
            }
        } else {
            let middle = (MatrixPillLayout.rows - 1) / 2
            for column in 0..<MatrixPillLayout.columns {
                let n = halfRows[column]
                if let rows = MatrixPillLayout.litRows(halfRows: n) {
                    for row in rows {
                        litPath.addEllipse(in: MatrixPillLayout.dotFrame(column: column, row: row, x: x, midY: midY, metrics: metrics))
                    }
                } else {
                    idlePath.addEllipse(in: MatrixPillLayout.dotFrame(column: column, row: middle, x: x, midY: midY, metrics: metrics))
                }
            }
        }
        PillMotion.withoutActions {
            // The unlit grid never changes, so its path is built once at the origin and the layer moves with the capsule.
            ghost.position = CGPoint(x: x, y: midY)
            lit.path = litPath
            idle.path = idlePath
            // A shadow path spares the glow an offscreen pass to find the shape's edge on every redraw.
            lit.shadowPath = litPath
            idle.shadowPath = idlePath
        }
    }

    /// The 13 x 7 grid of unlit dots with the grid's left edge at 0 and its middle at 0.
    private static func ghostPath(metrics: MatrixPillLayout.Metrics) -> CGPath {
        let path = CGMutablePath()
        for column in 0..<MatrixPillLayout.columns {
            for row in 0..<MatrixPillLayout.rows {
                path.addEllipse(in: MatrixPillLayout.dotFrame(column: column, row: row, x: 0, midY: 0, metrics: metrics))
            }
        }
        return path
    }

    private func applyHalfRows(_ next: [Int]) {
        guard next != halfRows else { return }
        halfRows = next
        rebuildMeter()
    }

    func showFractions(_ fractions: [Float]) {
        guard mode == .hold || mode == .locked else { return }
        applyHalfRows(isBars ? MatrixPillLayout.barHalfRows(fractions: fractions) : MatrixPillLayout.dotHalfRows(fractions: fractions))
    }

    func updateProcessing(time: TimeInterval) {
        guard mode == .processing else { return }
        let count = isBars ? MatrixPillLayout.barCount : MatrixPillLayout.columns
        let fractions = MatrixPillLayout.processingFractions(time: time, count: count)
        applyHalfRows(fractions.map { MatrixPillLayout.halfRows(fraction: $0) })
        let lit = MatrixPillLayout.processingDotsLit(time: time)
        guard lit != dotsLit else { return }
        dotsLit = lit
        PillMotion.withoutActions {
            for (i, dot) in processingDots.enumerated() { dot.opacity = i < lit ? 1 : 0.18 }
        }
    }

    // MARK: Controls

    private func discFill(_ control: PillControl) -> CGColor {
        let down = pressed == control, over = hovered == control
        switch control {
        case .cancel:
            return palette.controlForeground.withAlphaComponent(down ? 0.26 : over ? 0.17 : 0.10).cgColor
        case .stop:
            let base = palette.finishFill
            if down { return (base.blended(withFraction: 0.22, of: .black) ?? base).cgColor }
            if over { return (base.blended(withFraction: 0.20, of: .white) ?? base).cgColor }
            return base.cgColor
        }
    }

    private static func glyphPath(stop: Bool, in bounds: CGRect, k: CGFloat) -> CGPath {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if stop {
            let side: CGFloat = 8 * k
            return CGPath(
                roundedRect: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side),
                cornerWidth: 1.2 * k, cornerHeight: 1.2 * k, transform: nil
            )
        }
        let h: CGFloat = 3 * k
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x - h, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y + h))
        path.move(to: CGPoint(x: c.x - h, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y - h))
        return path
    }

    func setHovered(_ control: PillControl?) {
        guard control != hovered else { return }
        hovered = control
        refreshControls()
    }

    func setPressed(_ control: PillControl?) {
        guard control != pressed else { return }
        pressed = control
        refreshControls()
    }

    private func refreshControls() {
        for (control, disc) in discs {
            let down = pressed == control
            PillMotion.set(disc.shape, "fillColor", discFill(control), .ease(0.1))
            PillMotion.set(disc.group, "transform", CATransform3DMakeScale(down ? 0.93 : 1, down ? 0.93 : 1, 1), .ease(0.1))
        }
    }

    // MARK: Indicator

    private enum Lamp {
        case rec, ink, error, good, hidden
    }

    private var lampKind: Lamp {
        switch mode {
        case .hold: .rec
        case .locked: .hidden
        case .processing: .ink
        case .message: message?.isError == true ? .error : .ink
        case .readout(let readout):
            switch readout.tone {
            case .alert: .error
            case .quiet: .good
            case .question: .ink
            }
        }
    }

    private func applyLampColour() {
        let colour: NSColor
        switch lampKind {
        case .rec: colour = palette.rec
        case .error: colour = palette.error
        case .good: colour = goodColor
        case .ink, .hidden: colour = palette.ink
        }
        PillMotion.withoutActions {
            lamp.fillColor = colour.cgColor
            lamp.shadowColor = (isBars ? nil : colour.cgColor)
        }
    }

    /// The lamp breathes between 78% and 100% on a 2 s cycle while a hold recording runs, pulses while processing and
    /// flashes on an error; under Reduce Motion it stays steady.
    private func updateLampMotion() {
        lampReducedMotion = reduceMotion
        PillMotion.withoutActions { lamp.removeAnimation(forKey: "motion") }
        applyLampColour()
        let wanted: LampMotion
        switch lampKind {
        case .rec: wanted = .breathing
        case .ink: wanted = mode == .processing ? .pulsing : .steady
        case .error: wanted = .flashing
        case .good, .hidden: wanted = .steady
        }
        guard !reduceMotion, wanted != .steady else {
            lampMotion = .steady
            PillMotion.withoutActions { lamp.opacity = mode == .processing ? 0.7 : 1 }
            return
        }
        lampMotion = wanted
        let animation: CAAnimation
        switch wanted {
        case .breathing, .pulsing:
            let sweep = CABasicAnimation(keyPath: "opacity")
            let breathing = wanted == .breathing
            sweep.fromValue = breathing ? 1.0 : 0.5
            sweep.toValue = breathing ? 0.78 : 1.0
            sweep.duration = breathing ? 1.0 : 0.31
            sweep.autoreverses = true
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation = sweep
        default:
            let flash = CAKeyframeAnimation(keyPath: "opacity")
            flash.values = [1, 0.15, 1, 0.15, 1, 0.15, 1]
            flash.keyTimes = [0, 0.164, 0.327, 0.491, 0.655, 0.818, 0.98]
            flash.calculationMode = .discrete
            flash.duration = 1.1
            animation = flash
        }
        PillMotion.withoutActions { lamp.opacity = 1 }
        lamp.add(animation, forKey: "motion")
    }

    // MARK: Modes

    private func apply(_ new: MatrixPillLayout.Mode) {
        mode = new
        rowHeight = MatrixPillLayout.capsuleHeight(new, metrics: metrics)
        let moving = presented && !reduceMotion
        let fadeIn: PillMotion.Timing = presented ? .ease(reduceMotion ? 0.15 : 0.12, delay: reduceMotion ? 0 : 0.07) : .none
        let fadeOut: PillMotion.Timing = presented ? .ease(reduceMotion ? 0.15 : 0.05) : .none
        place(
            width: max(cardWidth ?? 0, MatrixPillLayout.capsuleWidth(new, metrics: metrics)),
            height: cardHeight + rowHeight,
            timing: moving ? .spring : .none
        )
        if new.readout != nil { applyHalfRows([Int](repeating: 0, count: halfRows.count)) }
        layoutContent()

        func fade(_ layer: CALayer, _ visible: Bool) {
            PillMotion.set(layer, "opacity", Float(visible ? 1 : 0), visible ? fadeIn : fadeOut)
        }
        var isMessage = false
        if case .message = new { isMessage = true }
        let readout = new.readout
        fade(lampGroup, new != .locked)
        fade(lips, new == .locked)
        fade(meterGroup, !isMessage)
        fade(recLabel, new == .hold || (readout.map { !$0.isClock && !$0.label.isEmpty } ?? false))
        fade(clockLabel, new == .locked || (readout?.isClock ?? false))
        fade(textGroup, isMessage)
        fade(processingGroup, new == .processing)
        dotsLit = -1
        for disc in discs.values { fade(disc.group, new == .locked) }
        updateLampMotion()
    }

    func showRecording(locked: Bool) {
        isLocked = locked
        apply(locked ? .locked : .hold)
    }

    func beginProcessing() {
        isLocked = false
        apply(.processing)
        updateProcessing(time: 0)
    }

    func showMessage(_ message: PillMessage, overRecording: Bool) {
        if !overRecording { isLocked = false }
        self.message = message
        messageOverRecording = overRecording
        messageScroll = 0
        block = MatrixPillLayout.messageBlock(
            headline: message.headline, detail: message.detail,
            headlineLineHeight: Typography.lineHeight(messageFont(isDetail: false)),
            detailLineHeight: Typography.lineHeight(messageFont(isDetail: true)), scale: scale, metrics: metrics,
            maxHeight: PillGeometry.maxPillSize.height * metrics.factor
        ) { text, isDetail in
            NSAttributedString(string: text, attributes: [.font: self.messageFont(isDetail: isDetail)]).size().width
        }
        apply(.message(width: block.width, height: block.height))
    }

    /// The font setting changed. Matrix messages follow it; Minimal's system text doesn't.
    func applyTypography(_ new: Typography) {
        typography = new
        guard flavor == .matrix, case .message = mode, let message else { return }
        showMessage(message, overRecording: messageOverRecording)
    }

    func setElapsed(_ seconds: TimeInterval?) {
        guard let seconds else { return }
        let text = PillTimeline.timerText(seconds: Int(seconds))
        guard text != clockText else { return }
        clockText = text
        layoutLabels()
    }

    /// `offset` runs from 0 to `-messageScrollDistance`, as for the marquee, and here moves the text up.
    func setMessageOffset(_ offset: Int) {
        let next = min(block.overflow, max(0, CGFloat(-offset)))
        guard next != messageScroll else { return }
        messageScroll = next
        PillMotion.withoutActions { textGroup.position = CGPoint(x: 0, y: messageScroll - block.overflow / 2) }
    }

    // MARK: Card

    /// Grows the capsule upward to hold a card `width` wide and `height` tall above the row, which keeps saying what it
    /// said, or `readout` when `showReadout` is set.
    func growCard(width: CGFloat, height: CGFloat, readout: CardReadout, showReadout: Bool) {
        cardWidth = width
        cardHeight = height
        cardReadout = readout
        PillMotion.withoutActions { bodyShape.setColors(bodyColours) }
        apply(showReadout ? .readout(readout) : mode)
    }

    /// The card's readout changed without the card (the countdown ticked).
    func updateCardReadout(_ readout: CardReadout) {
        cardReadout = readout
        if mode.readout != nil {
            mode = .readout(readout)
            layoutLabels()
        }
        applyCardChrome()
    }

    /// Shows the card's readout in the row, for a card with no recording or message under it.
    func showCardReadout(_ readout: CardReadout) {
        cardReadout = readout
        apply(.readout(readout))
    }

    /// Back to the plain pill. A row that was only the card's readout stays as it is.
    func shrinkCard() {
        cardWidth = nil
        cardHeight = 0
        cardReadout = nil
        PillMotion.withoutActions { bodyShape.setColors(bodyColours) }
        apply(mode)
    }

    // MARK: Show and hide

    private func pillTransform(scale s: CGFloat, drop: CGFloat) -> CATransform3D {
        let pill = capsule(width: width, height: height)
        let dx = (1 - s) * (pill.midX - bounds.midX)
        let dy = (1 - s) * (pill.midY - bounds.midY) - drop
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s, s, 1)
    }

    /// How long the pill takes to appear.
    static func appearDuration(reduceMotion: Bool) -> TimeInterval { reduceMotion ? 0.15 : 0.26 }

    private static let disappearCurve = (x1: 0.55, y1: 0.055, x2: 0.675, y2: 0.19)

    /// How far a fade-out started `elapsed` ago has got, 1 untouched down to 0 gone, on the same ease-in curve.
    static func fadeOutOpacity(from start: Float, elapsed: TimeInterval, duration: TimeInterval) -> Float {
        guard duration > 0 else { return 0 }
        let t = min(1, max(0, elapsed / duration))
        // Solve the bezier's x for t by bisection, then read y.
        let c = disappearCurve
        func bezier(_ u: Double, _ a: Double, _ b: Double) -> Double {
            3 * (1 - u) * (1 - u) * u * a + 3 * (1 - u) * u * u * b + u * u * u
        }
        var low = 0.0, high = 1.0
        for _ in 0..<24 {
            let mid = (low + high) / 2
            if bezier(mid, c.x1, c.x2) < t { low = mid } else { high = mid }
        }
        let progress = bezier((low + high) / 2, c.y1, c.y2)
        return Float(Double(start) * (1 - progress))
    }

    /// 260 ms ease-out: fades in, grows from 90 percent and rises 5 pt. Fade only under Reduce Motion. A pill still
    /// fading out when this runs is not snapped to nothing: it turns round and fades back up from where it is.
    func appear(reduceMotion: Bool) {
        let resumed = fadingOutOpacity()
        presented = true
        fadeOut = nil
        appearStartOpacity = resumed ?? 0
        if resumed == nil {
            PillMotion.withoutActions {
                container.opacity = 0
                container.transform = reduceMotion ? CATransform3DIdentity : pillTransform(scale: Self.appearScale, drop: Self.travel * k)
                lampGroup.opacity = 0
                lips.opacity = 0
                meterGroup.opacity = 0
                recLabel.opacity = 0
                clockLabel.opacity = 0
                textGroup.opacity = 0
                processingGroup.opacity = 0
                discs.values.forEach { $0.group.opacity = 0 }
            }
        }
        clockText = "0:00"
        rowHeight = metrics.height
        place(width: max(cardWidth ?? 0, metrics.heldWidth), height: cardHeight + rowHeight, timing: .none)
        layoutContent()
        let timing: PillMotion.Timing = .ease(Self.appearDuration(reduceMotion: reduceMotion))
        PillMotion.set(container, "opacity", Float(1), timing)
        PillMotion.set(container, "transform", CATransform3DIdentity, reduceMotion ? .none : timing)
    }

    /// The opacity the pill has now while it is still fading out, nil when it is not, or has all but gone.
    private func fadingOutOpacity() -> Float? {
        guard let fadeOut else { return nil }
        let now = Self.fadeOutOpacity(from: fadeOut.from, elapsed: CACurrentMediaTime() - fadeOut.start, duration: fadeOut.duration)
        return now > 0.01 ? now : nil
    }

    /// 160 ms ease-in: fades, shrinks to 90 percent and drops 5 pt.
    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        let duration: TimeInterval = reduceMotion ? 0.12 : 0.16
        fadeOut = (CACurrentMediaTime(), duration, fadingOutOpacity() ?? Float(container.opacity))
        presented = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        PillMotion.set(container, "opacity", Float(0), .easeIn(duration))
        if !reduceMotion {
            PillMotion.set(container, "transform", pillTransform(scale: Self.appearScale, drop: Self.travel * k), .easeIn(duration))
        }
        CATransaction.commit()
    }
}

extension MatrixPillLayout.Mode {
    var readout: CardReadout? {
        if case .readout(let readout) = self { return readout }
        return nil
    }

    var isMessage: Bool {
        if case .message = self { return true }
        return false
    }
}
