import AppKit
import QuartzCore

/// The Ring pill: a round body with spokes around a circle that follow the live level, and a small centre dot that
/// swells with it. Processing settles the spokes into a thin ring with a comet sweeping round it. Under Reduce Motion
/// nothing rotates or pulses: a static ring shows the level as one filled arc. A locked pill widens to a capsule for the
/// cancel and stop controls and a message turns the body into a capsule too. It follows the system appearance with the
/// Minimal palette. Drawn as vector shape layers; the view never takes events itself, the host view over it does.
@MainActor
final class RingPillView: NSView, PillSkinView {
    static let travel: CGFloat = 5
    static let appearScale: CGFloat = 0.9
    static let trackAlpha: CGFloat = 0.25

    /// Which parts are showing, as layer opacities.
    struct Visibility: Equatable {
        var spokes: Float, dot: Float, track: Float, comet: Float, arc: Float, text: Float
    }

    static func visibility(mode: RingPillLayout.Mode, reduceMotion: Bool) -> Visibility {
        switch mode {
        case .hold, .locked:
            reduceMotion
                ? Visibility(spokes: 0, dot: 1, track: 1, comet: 0, arc: 1, text: 0)
                : Visibility(spokes: 1, dot: 1, track: 0, comet: 0, arc: 0, text: 0)
        case .processing:
            reduceMotion
                ? Visibility(spokes: 0, dot: 1, track: 1, comet: 0, arc: 1, text: 0)
                : Visibility(spokes: 0, dot: 1, track: 1, comet: 1, arc: 0, text: 0)
        case .message:
            Visibility(spokes: 0, dot: 0, track: 0, comet: 0, arc: 0, text: 1)
        }
    }

    private struct Disc {
        let group = CALayer()
        let disc = CAShapeLayer()
        let glyph = CAShapeLayer()
    }

    private let container = CALayer()
    private let ambient = CAShapeLayer()
    private let contact = CAShapeLayer()
    private let body = CAGradientLayer()
    private let bodyMask = CAShapeLayer()
    private let rim = CAShapeLayer()
    // The ring's parts, readable by tests.
    let track = CAShapeLayer()
    let cometGroup = CALayer()
    private let cometTail = CAGradientLayer()
    private let cometMask = CAShapeLayer()
    private let cometHead = CAShapeLayer()
    let arc = CAShapeLayer()
    let spokes = CAShapeLayer()
    let dot = CAShapeLayer()
    private let textClip = CALayer()
    private let textGroup = CALayer()
    private var lineLayers: [CATextLayer] = []
    private let discs: [PillControl: Disc] = [.cancel: Disc(), .stop: Disc()]

    /// The pill size this view is drawn at; a size change builds a new view.
    let pillScale: PillScale
    private let metrics: RingPillLayout.Metrics
    private let classicMetrics: ClassicPillLayout.Metrics
    private var k: CGFloat { metrics.factor }
    private var scale: CGFloat = 2
    private(set) var mode = RingPillLayout.Mode.hold
    private var width: CGFloat
    private var height: CGFloat
    /// The body's size as last placed, before any spring has run. For tests.
    var bodySize: CGSize { CGSize(width: width, height: height) }
    private var presented = false
    private(set) var typography = Typography.current()
    private var message: PillMessage?
    private var messageOverRecording = false
    private var block: ClassicPillLayout.MessageBlock
    private var messageScroll: CGFloat = 0
    private var hovered: PillControl?
    private var pressed: PillControl?
    private(set) var isLocked = false
    private var palette: SquirclePalette
    /// The last spoke levels, and the ones the spokes had when processing began, for settling.
    private(set) var spokeLevels = [Float](repeating: 0, count: RingPillLayout.spokeCount)
    private var settleFrom: [Float]?
    private(set) var level: Float = 0
    private var processingTime: TimeInterval = 0
    private var appliedReduceMotion = false

    /// The laid-out lines of the current message, for tests.
    var messageLines: [ClassicPillLayout.MessageLine] { block.lines }
    var messageSize: CGSize {
        guard block.width > 0 else { return .zero }
        return CGSize(width: max(metrics.diameter, block.width), height: max(metrics.diameter, block.height))
    }
    var messageScrollDistance: Int { Int(block.overflow.rounded(.up)) }

    var controlFrames: [PillControl: CGRect] {
        guard isLocked, case .locked = mode else { return [:] }
        return RingPillLayout.controlFrames(capsule: capsule(width: width, height: height), metrics: metrics)
    }

    /// The body rect in this view's coordinates, for tests and the card.
    var bodyRect: CGRect { capsule(width: width, height: height) }

    init(frame: NSRect, size: PillScale = .standard) {
        pillScale = size
        metrics = RingPillLayout.Metrics(size)
        classicMetrics = ClassicPillLayout.Metrics(size)
        width = metrics.diameter
        height = metrics.diameter
        block = ClassicPillLayout.MessageBlock(width: 0, height: metrics.diameter, lines: [])
        palette = SquirclePalette.resolve(.minimal, dark: true)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

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
        body.mask = bodyMask
        bodyMask.fillColor = NSColor.black.cgColor
        container.addSublayer(body)
        rim.fillColor = nil
        rim.lineWidth = k
        container.addSublayer(rim)

        track.fillColor = nil
        track.lineWidth = metrics.ringWidth
        container.addSublayer(track)
        arc.fillColor = nil
        arc.lineWidth = metrics.ringWidth * 1.5
        arc.lineCap = .round
        container.addSublayer(arc)
        let cometSide = metrics.diameter
        cometGroup.bounds = CGRect(x: 0, y: 0, width: cometSide, height: cometSide)
        container.addSublayer(cometGroup)
        let centre = CGPoint(x: cometSide / 2, y: cometSide / 2)
        cometTail.frame = cometGroup.bounds
        cometTail.type = .conic
        cometTail.startPoint = CGPoint(x: 0.5, y: 0.5)
        cometTail.endPoint = CGPoint(x: 0.5, y: 1)
        let stops = RingPillLayout.cometStops()
        cometTail.locations = stops.map { NSNumber(value: Double($0.location)) }
        cometMask.fillColor = nil
        cometMask.strokeColor = NSColor.black.cgColor
        cometMask.lineWidth = metrics.ringWidth * 1.5
        cometMask.path = CGPath(
            ellipseIn: CGRect(x: centre.x - metrics.ringRadius, y: centre.y - metrics.ringRadius,
                              width: 2 * metrics.ringRadius, height: 2 * metrics.ringRadius), transform: nil
        )
        cometTail.mask = cometMask
        cometGroup.addSublayer(cometTail)
        let headRadius = metrics.ringWidth * 0.75
        cometHead.path = CGPath(
            ellipseIn: CGRect(x: centre.x - headRadius, y: centre.y + metrics.ringRadius - headRadius, width: 2 * headRadius, height: 2 * headRadius),
            transform: nil
        )
        cometGroup.addSublayer(cometHead)

        spokes.fillColor = nil
        spokes.lineWidth = metrics.spokeWidth
        spokes.lineCap = .round
        container.addSublayer(spokes)
        container.addSublayer(dot)

        textGroup.opacity = 0
        textClip.anchorPoint = .zero
        textClip.masksToBounds = true
        textClip.addSublayer(textGroup)
        container.addSublayer(textClip)

        for (control, disc) in discs {
            let isStop = control == .stop
            disc.group.bounds = CGRect(origin: .zero, size: CGSize(width: metrics.controlDiameter, height: metrics.controlDiameter))
            disc.group.opacity = 0
            disc.disc.path = CGPath(ellipseIn: disc.group.bounds, transform: nil)
            disc.glyph.path = Self.glyphPath(stop: isStop, in: disc.group.bounds, k: k)
            disc.glyph.lineWidth = 1.5 * k
            disc.glyph.lineCap = .round
            disc.group.addSublayer(disc.disc)
            disc.group.addSublayer(disc.glyph)
            container.addSublayer(disc.group)
        }
        applyPalette()
        applyScale()
        relayout()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

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
        applyPalette()
        layoutText()
    }

    // MARK: Colours

    private var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    private func applyPalette() {
        palette = SquirclePalette.resolve(.minimal, dark: isDark)
        let p = palette
        PillMotion.withoutActions {
            ambient.shadowOpacity = p.ambientShadow
            contact.shadowOpacity = p.contactShadow
            body.colors = [p.bodyTop.cgColor, p.bodyBottom.cgColor]
            rim.strokeColor = p.hairline.cgColor
            track.strokeColor = p.ink.withAlphaComponent(Self.trackAlpha).cgColor
            arc.strokeColor = p.ink.cgColor
            spokes.strokeColor = p.ink.cgColor
            dot.fillColor = p.ink.cgColor
            cometTail.colors = RingPillLayout.cometStops().map { p.ink.withAlphaComponent($0.alpha).cgColor }
            cometHead.fillColor = p.ink.cgColor
            for (control, disc) in discs {
                disc.disc.fillColor = discColor(control, hovered: false, pressed: false)
                disc.glyph.fillColor = control == .stop ? p.finishGlyph.cgColor : nil
                disc.glyph.strokeColor = control == .stop ? nil : p.cancelGlyph.cgColor
            }
        }
    }

    private func discColor(_ control: PillControl, hovered: Bool, pressed: Bool) -> CGColor {
        switch control {
        case .cancel: palette.controlForeground.withAlphaComponent(pressed ? 0.26 : hovered ? 0.17 : 0.10).cgColor
        case .stop: palette.finishFill.withAlphaComponent(pressed ? 0.7 : hovered ? 0.85 : 1).cgColor
        }
    }

    // MARK: Geometry

    private func applyScale() {
        scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in allLayers { layer.contentsScale = scale }
        container.contentsScale = scale
    }

    private var allLayers: [CALayer] {
        [ambient, contact, body, bodyMask, rim, track, arc, cometGroup, cometTail, cometMask, cometHead, spokes, dot, textClip, textGroup]
            + lineLayers + discs.values.flatMap { [$0.group, $0.disc, $0.glyph] }
    }

    private func capsule(width: CGFloat, height: CGFloat) -> CGRect {
        ClassicPillLayout.capsuleFrame(
            width: width, height: height, bounds: bounds.size, bottomMargin: PillGeometry.verticalMargin, scale: scale
        )
    }

    private func bodyPath(_ rect: CGRect, inset: CGFloat = 0) -> CGPath {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(metrics.cornerRadius - inset, r.height / 2, r.width / 2)
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    private func relayout() {
        place(width: width, height: height, timing: .none)
        refreshContent()
        layoutText()
    }

    private func place(width newWidth: CGFloat, height newHeight: CGFloat, timing: PillMotion.Timing) {
        width = newWidth
        height = newHeight
        let rect = capsule(width: newWidth, height: newHeight)
        let path = bodyPath(rect)
        PillMotion.set(bodyMask, "path", path, timing)
        PillMotion.set(ambient, "shadowPath", path, timing)
        PillMotion.set(contact, "shadowPath", path, timing)
        PillMotion.set(rim, "path", bodyPath(rect, inset: 0.5 * k), timing)
        PillMotion.withoutActions {
            body.frame = container.bounds
            body.startPoint = CGPoint(x: 0.5, y: rect.maxY / max(1, bounds.height))
            body.endPoint = CGPoint(x: 0.5, y: rect.minY / max(1, bounds.height))
        }
        let frames = RingPillLayout.controlFrames(capsule: rect, metrics: metrics)
        for (control, disc) in discs {
            guard let frame = frames[control] else { continue }
            PillMotion.set(disc.group, "position", NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), timing)
        }
    }

    /// The ring parts follow the body's middle; the body is a circle whenever they show.
    private func refreshContent() {
        let rect = capsule(width: width, height: height)
        let centre = CGPoint(x: rect.midX, y: rect.midY)
        let reduce = reduceMotion
        PillMotion.withoutActions {
            let spokePath = CGMutablePath()
            for index in 0..<spokeLevels.count {
                let angle = RingPillLayout.spokeAngle(index: index, count: spokeLevels.count)
                let length = RingPillLayout.spokeLength(fraction: spokeLevels[index], metrics: metrics)
                let (from, to) = RingPillLayout.spokeEnds(angle: angle, length: length, centre: centre, metrics: metrics)
                spokePath.move(to: from)
                spokePath.addLine(to: to)
            }
            spokes.path = spokePath

            let radius = reduce ? RingPillLayout.dotRadius(level: 0.4, metrics: metrics)
                : (mode == .processing ? metrics.dotRadius : RingPillLayout.dotRadius(level: level, metrics: metrics))
            dot.path = CGPath(
                ellipseIn: CGRect(x: centre.x - radius, y: centre.y - radius, width: 2 * radius, height: 2 * radius), transform: nil
            )

            track.path = CGPath(
                ellipseIn: CGRect(x: centre.x - metrics.ringRadius, y: centre.y - metrics.ringRadius,
                                  width: 2 * metrics.ringRadius, height: 2 * metrics.ringRadius), transform: nil
            )
            let sweep = mode == .processing ? CGFloat.pi / 2 : RingPillLayout.levelSweep(level: level)
            if sweep > 0.001 {
                arc.path = Self.arc(centre: centre, radius: metrics.ringRadius, from: 0, to: sweep)
            } else {
                arc.path = nil
            }
            cometGroup.position = centre
            cometGroup.transform = CATransform3DMakeRotation(
                -(reduce ? 0 : RingPillLayout.cometHeadAngle(time: processingTime)), 0, 0, 1
            )
        }
    }

    // MARK: Text

    private func layoutText() {
        let rect = capsule(width: width, height: height)
        while lineLayers.count < block.lines.count {
            let layer = CATextLayer()
            layer.alignmentMode = .center
            layer.truncationMode = .none
            layer.isWrapped = false
            layer.contentsScale = scale
            textGroup.addSublayer(layer)
            lineLayers.append(layer)
        }
        let isError = message?.isError == true
        PillMotion.withoutActions {
            // A capped message starts with its first line at the top of the room and scrolls up from there.
            let pad = block.overflow > 0 ? classicMetrics.messageVerticalPadding : 0
            let viewport = CGRect(x: rect.minX, y: rect.minY + pad, width: rect.width, height: max(0, rect.height - 2 * pad))
            textClip.bounds = viewport
            textClip.position = viewport.origin
            textGroup.position = CGPoint(x: 0, y: messageScroll - block.overflow / 2)
            for (index, layer) in lineLayers.enumerated() {
                guard index < block.lines.count else {
                    layer.isHidden = true
                    continue
                }
                let line = block.lines[index]
                let font = typography.font(line.isDetail ? .pillDetail : .pillMessage, scale: k)
                let color = line.isDetail ? palette.text.withAlphaComponent(ClassicPillView.detailAlpha) : (isError ? palette.error : palette.text)
                let baseline = rect.midY - line.centerOffset - font.capHeight / 2
                layer.isHidden = false
                layer.string = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color])
                layer.frame = CGRect(
                    x: rect.minX + classicMetrics.messagePadding,
                    y: ClassicPillLayout.snap(baseline + font.descender, scale: scale),
                    width: rect.width - 2 * classicMetrics.messagePadding, height: Typography.lineHeight(font)
                )
            }
        }
    }

    /// A clockwise arc between two angles measured clockwise from twelve o'clock.
    private static func arc(centre: CGPoint, radius: CGFloat, from start: CGFloat, to end: CGFloat) -> CGPath {
        let path = CGMutablePath()
        path.addArc(center: centre, radius: radius, startAngle: .pi / 2 - start, endAngle: .pi / 2 - end, clockwise: true)
        return path
    }

    private static func glyphPath(stop: Bool, in bounds: CGRect, k: CGFloat) -> CGPath {
        let c = CGPoint(x: bounds.midX, y: bounds.midY)
        if stop {
            let side: CGFloat = 7 * k
            return CGPath(
                roundedRect: CGRect(x: c.x - side / 2, y: c.y - side / 2, width: side, height: side),
                cornerWidth: 1.5 * k, cornerHeight: 1.5 * k, transform: nil
            )
        }
        let h: CGFloat = 3.1 * k
        let path = CGMutablePath()
        path.move(to: CGPoint(x: c.x - h, y: c.y - h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y + h))
        path.move(to: CGPoint(x: c.x - h, y: c.y + h))
        path.addLine(to: CGPoint(x: c.x + h, y: c.y - h))
        return path
    }

    // MARK: Modes

    /// Replaces the system Reduce Motion setting; tests set it.
    var reduceMotionOverride: Bool?
    private var reduceMotion: Bool { reduceMotionOverride ?? NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func apply(_ new: RingPillLayout.Mode) {
        let old = mode
        mode = new
        let reduce = reduceMotion
        appliedReduceMotion = reduce
        let moving = presented && !reduce
        let fadeIn: PillMotion.Timing = presented ? .ease(reduce ? 0.15 : 0.12, delay: reduce ? 0 : 0.07) : .none
        let fadeOut: PillMotion.Timing = presented ? .ease(reduce ? 0.15 : 0.05) : .none
        place(
            width: RingPillLayout.capsuleWidth(new, metrics: metrics),
            height: RingPillLayout.capsuleHeight(new, metrics: metrics),
            timing: moving ? .spring : .none
        )
        let v = Self.visibility(mode: new, reduceMotion: reduce)
        let fades: [(CALayer, Float)] = [(spokes, v.spokes), (dot, v.dot), (track, v.track), (cometGroup, v.comet), (arc, v.arc), (textGroup, v.text)]
        for (layer, opacity) in fades {
            PillMotion.set(layer, "opacity", opacity, opacity > 0 ? fadeIn : fadeOut)
        }
        let controlsIn = new == .locked
        for disc in discs.values {
            PillMotion.set(disc.group, "opacity", controlsIn ? Float(1) : 0, controlsIn ? (old != .locked ? fadeIn : .none) : fadeOut)
        }
        refreshContent()
        layoutText()
    }

    func showRecording(locked: Bool) {
        isLocked = locked
        settleFrom = nil
        processingTime = 0
        apply(locked ? .locked : .hold)
    }

    func beginProcessing() {
        isLocked = false
        settleFrom = spokeLevels
        processingTime = 0
        apply(.processing)
    }

    func showMessage(_ message: PillMessage, overRecording: Bool) {
        if !overRecording { isLocked = false }
        self.message = message
        messageOverRecording = overRecording
        messageScroll = 0
        block = ClassicPillLayout.messageBlock(
            headline: message.headline, detail: message.detail,
            headlineLineHeight: Typography.lineHeight(typography.font(.pillMessage, scale: k)),
            detailLineHeight: Typography.lineHeight(typography.font(.pillDetail, scale: k)), scale: scale, metrics: classicMetrics,
            maxHeight: PillGeometry.maxPillSize.height * k
        ) { text, isDetail in
            NSAttributedString(
                string: text, attributes: [.font: self.typography.font(isDetail ? .pillDetail : .pillMessage, scale: self.k)]
            ).size().width
        }
        apply(.message(width: block.width, height: block.height))
    }

    /// The font setting changed: a message on screen is measured and laid out again with the new faces.
    func applyTypography(_ new: Typography) {
        typography = new
        guard case .message = mode, let message else { return }
        showMessage(message, overRecording: messageOverRecording)
    }

    func showFractions(_ fractions: [Float]) {
        guard mode == .hold || mode == .locked else { return }
        if reduceMotion != appliedReduceMotion { apply(mode) }
        spokeLevels = RingPillLayout.spokeFractions(from: fractions)
        level = RingPillLayout.overallLevel(fractions)
        refreshContent()
    }

    func updateProcessing(time: TimeInterval) {
        guard mode == .processing else { return }
        if reduceMotion != appliedReduceMotion { apply(mode) }
        processingTime = time
        if let from = settleFrom {
            let remaining = Float(1 - RingPillLayout.settleProgress(time: time))
            spokeLevels = from.map { $0 * remaining }
            if remaining == 0 { settleFrom = nil }
        }
        level = 0
        refreshContent()
    }

    func setElapsed(_ seconds: TimeInterval?) {}

    /// `offset` runs from 0 to `-messageScrollDistance`, as for the marquee, and here moves the text up.
    func setMessageOffset(_ offset: Int) {
        let next = min(block.overflow, max(0, CGFloat(-offset)))
        guard next != messageScroll else { return }
        messageScroll = next
        PillMotion.withoutActions { textGroup.position = CGPoint(x: 0, y: messageScroll - block.overflow / 2) }
    }

    // MARK: Controls

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
            PillMotion.set(disc.disc, "fillColor", discColor(control, hovered: hovered == control, pressed: down), .ease(0.1))
            PillMotion.set(disc.group, "transform", CATransform3DMakeScale(down ? 0.92 : 1, down ? 0.92 : 1, 1), .ease(0.1))
        }
    }

    // MARK: Show and hide

    private func pillTransform(scale s: CGFloat, drop: CGFloat) -> CATransform3D {
        let pill = capsule(width: width, height: height)
        let dx = (1 - s) * (pill.midX - bounds.midX)
        let dy = (1 - s) * (pill.midY - bounds.midY) - drop
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s, s, 1)
    }

    /// 260 ms ease-out: fades in, grows from 90 percent and rises 5 pt. Fade only under Reduce Motion.
    func appear(reduceMotion: Bool) {
        presented = true
        PillMotion.withoutActions {
            container.opacity = 0
            container.transform = reduceMotion ? CATransform3DIdentity : pillTransform(scale: Self.appearScale, drop: Self.travel * k)
            for layer in [spokes, dot, track, cometGroup, arc, textGroup] { layer.opacity = 0 }
            discs.values.forEach { $0.group.opacity = 0 }
        }
        place(width: metrics.diameter, height: metrics.diameter, timing: .none)
        refreshContent()
        let timing: PillMotion.Timing = .ease(reduceMotion ? 0.15 : 0.26)
        PillMotion.set(container, "opacity", Float(1), timing)
        PillMotion.set(container, "transform", CATransform3DIdentity, reduceMotion ? .none : timing)
    }

    /// 160 ms ease-in: fades, shrinks to 90 percent and drops 5 pt.
    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        presented = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let duration: TimeInterval = reduceMotion ? 0.12 : 0.16
        PillMotion.set(container, "opacity", Float(0), .easeIn(duration))
        if !reduceMotion {
            PillMotion.set(container, "transform", pillTransform(scale: Self.appearScale, drop: Self.travel * k), .easeIn(duration))
        }
        CATransaction.commit()
    }
}
