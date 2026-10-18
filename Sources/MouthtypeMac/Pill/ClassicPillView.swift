import AppKit
import QuartzCore

/// The classic pill: a dark capsule with ten bars, drawn as vector shape layers so it stays crisp at any scale.
/// Width changes between states are springs that settle without visible overshoot; under Reduce Motion they snap
/// and the content cross-fades instead. The view never takes events itself, the host view over it does.
@MainActor
final class ClassicPillView: NSView, PillSkinView {
    static let fill = NSColor(hex: 0x1A1A1A)
    static let stroke = NSColor(hex: 0x4D4A42)
    static let ink = NSColor(hex: 0xFFFFEB)
    /// The red the prototype's Minimal pill uses for errors.
    static let errorInk = NSColor(hex: 0xFF6B5E)
    static let detailAlpha: CGFloat = 0.62

    private enum Timing {
        case none, spring
        case ease(TimeInterval, delay: TimeInterval = 0)
        case easeIn(TimeInterval)
    }

    private static let easeOutCubic = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
    private static let easeInCubic = CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19)
    /// How far the pill rises as it appears and drops as it leaves, and the scale it grows from.
    private static let travel: CGFloat = 5
    private static let appearScale: CGFloat = 0.9

    private struct Disc {
        let group = CALayer()
        let disc = CAShapeLayer()
        let glyph = CAShapeLayer()
    }

    private let container = CALayer()
    private let ambient = CAShapeLayer()
    private let contact = CAShapeLayer()
    private let body = CAShapeLayer()
    private let rim = CAShapeLayer()
    private let barsLayer = CALayer()
    private let bars = (0..<BarModel.barCount).map { _ in CAShapeLayer() }
    private let textGroup = CALayer()
    private var lineLayers: [CATextLayer] = []
    private let discs: [PillControl: Disc] = [.cancel: Disc(), .stop: Disc()]

    /// The pill size this view is drawn at; a size change builds a new view.
    let pillScale: PillScale
    private let metrics: ClassicPillLayout.Metrics
    private var k: CGFloat { metrics.factor }
    private var scale: CGFloat = 2
    private var mode = ClassicPillLayout.Mode.hold
    private var width: CGFloat
    private var height: CGFloat
    private var presented = false
    private(set) var typography = Typography.current()
    private var message: PillMessage?
    private var messageOverRecording = false
    private var block: ClassicPillLayout.MessageBlock
    private var heights: [CGFloat]
    private var hovered: PillControl?
    private var pressed: PillControl?
    private(set) var isLocked = false
    /// The laid-out lines of the current message, for tests.
    var messageLines: [ClassicPillLayout.MessageLine] { block.lines }
    var messageSize: CGSize { CGSize(width: block.width, height: block.height) }

    var messageScrollDistance: Int { 0 }

    var controlFrames: [PillControl: CGRect] {
        guard isLocked, mode == .locked else { return [:] }
        return ClassicPillLayout.controlFrames(capsule: capsule(width: width), metrics: metrics)
    }

    init(frame: NSRect, size: PillScale = .standard) {
        pillScale = size
        metrics = ClassicPillLayout.Metrics(size)
        width = metrics.dotWidth
        height = metrics.height
        block = ClassicPillLayout.MessageBlock(width: 0, height: metrics.height, lines: [])
        heights = [CGFloat](repeating: ClassicPillLayout.barMetrics(scale: 2, metrics: metrics).width, count: BarModel.barCount)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        container.frame = bounds
        container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.opacity = 0
        layer?.addSublayer(container)

        for (shadow, opacity, radius, drop) in [(ambient, Float(0.50), 6 * k, 4 * k), (contact, 0.35, 1 * k, 0.8 * k)] {
            shadow.fillColor = nil
            shadow.shadowColor = NSColor.black.cgColor
            shadow.shadowOpacity = opacity
            shadow.shadowRadius = radius
            shadow.shadowOffset = CGSize(width: 0, height: -drop)
            container.addSublayer(shadow)
        }
        body.fillColor = Self.fill.withAlphaComponent(0.96).cgColor
        container.addSublayer(body)
        rim.fillColor = nil
        rim.strokeColor = Self.stroke.cgColor
        rim.lineWidth = k
        container.addSublayer(rim)

        container.addSublayer(barsLayer)
        for bar in bars {
            bar.fillColor = Self.ink.cgColor
            barsLayer.addSublayer(bar)
        }

        textGroup.opacity = 0
        container.addSublayer(textGroup)

        for (control, disc) in discs {
            let isStop = control == .stop
            disc.group.bounds = CGRect(origin: .zero, size: CGSize(width: metrics.controlDiameter, height: metrics.controlDiameter))
            disc.group.opacity = 0
            disc.disc.path = CGPath(ellipseIn: disc.group.bounds, transform: nil)
            disc.glyph.path = Self.glyphPath(stop: isStop, in: disc.group.bounds, k: k)
            disc.glyph.fillColor = isStop ? Self.fill.cgColor : nil
            disc.glyph.strokeColor = isStop ? nil : NSColor(hex: 0xFCFCFB).cgColor
            disc.glyph.lineWidth = 1.5 * k
            disc.glyph.lineCap = .round
            disc.group.addSublayer(disc.disc)
            disc.group.addSublayer(disc.glyph)
            container.addSublayer(disc.group)
            disc.disc.fillColor = Self.discColor(control, hovered: false, pressed: false)
        }
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

    // MARK: Geometry

    private func applyScale() {
        scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        for layer in allLayers { layer.contentsScale = scale }
        container.contentsScale = scale
    }

    private var allLayers: [CALayer] {
        [ambient, contact, body, rim, textGroup] + lineLayers + bars + discs.values.flatMap { [$0.group, $0.disc, $0.glyph] }
    }

    private func capsule(width: CGFloat, height: CGFloat? = nil) -> CGRect {
        ClassicPillLayout.capsuleFrame(
            width: width, height: height ?? self.height, bounds: bounds.size, bottomMargin: PillGeometry.verticalMargin, scale: scale
        )
    }

    private func capsulePath(_ rect: CGRect, inset: CGFloat = 0) -> CGPath {
        let r = rect.insetBy(dx: inset, dy: inset)
        let radius = min(metrics.cornerRadius - inset, r.height / 2)
        return CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)
    }

    /// Puts everything where the current mode and width say, without animating. Used after a scale or size change.
    private func relayout() {
        place(width: width, height: height, timing: .none)
        layoutBars()
        layoutText()
    }

    private func place(width newWidth: CGFloat, height newHeight: CGFloat? = nil, timing: Timing) {
        let newHeight = newHeight ?? metrics.height
        width = newWidth
        height = newHeight
        let rect = capsule(width: newWidth, height: newHeight)
        let path = capsulePath(rect)
        set(body, "path", path, timing)
        set(ambient, "shadowPath", path, timing)
        set(contact, "shadowPath", path, timing)
        set(rim, "path", capsulePath(rect, inset: 0.5 * k), timing)
        // Controls travel with the capsule's ends while hidden too, so they fade in where they will sit.
        let frames = ClassicPillLayout.controlFrames(capsule: rect, metrics: metrics)
        for (control, disc) in discs {
            guard let frame = frames[control] else { continue }
            set(disc.group, "position", NSValue(point: CGPoint(x: frame.midX, y: frame.midY)), timing)
        }
    }

    private func layoutBars() {
        let rect = capsule(width: width)
        let frames = ClassicPillLayout.barFrames(capsule: rect, heights: heights, scale: scale, metrics: metrics)
        withoutActions {
            for (bar, frame) in zip(bars, frames) {
                bar.frame = frame
                bar.path = CGPath(
                    roundedRect: CGRect(origin: .zero, size: frame.size),
                    cornerWidth: min(frame.width, frame.height) / 2, cornerHeight: min(frame.width, frame.height) / 2,
                    transform: nil
                )
            }
        }
    }

    private func layoutText() {
        let rect = capsule(width: width)
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
        withoutActions {
            for (index, layer) in lineLayers.enumerated() {
                guard index < block.lines.count else {
                    layer.isHidden = true
                    continue
                }
                let line = block.lines[index]
                let font = typography.font(line.isDetail ? .pillDetail : .pillMessage, scale: k)
                let color = line.isDetail ? Self.ink.withAlphaComponent(Self.detailAlpha) : (isError ? Self.errorInk : Self.ink)
                let descent = -font.descender
                // Cap-height centred on the line's middle, which reads as centred for sentence-case text.
                let baseline = rect.midY - line.centerOffset - font.capHeight / 2
                layer.isHidden = false
                layer.string = NSAttributedString(string: line.text, attributes: [.font: font, .foregroundColor: color])
                layer.frame = CGRect(
                    x: rect.minX + metrics.messagePadding,
                    y: ClassicPillLayout.snap(baseline - descent, scale: scale),
                    width: rect.width - 2 * metrics.messagePadding, height: Typography.lineHeight(font)
                )
            }
        }
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

    private static func discColor(_ control: PillControl, hovered: Bool, pressed: Bool) -> CGColor {
        switch (control, pressed, hovered) {
        case (.cancel, true, _): NSColor(hex: 0x5C5C5A).cgColor
        case (.cancel, _, true): NSColor(hex: 0x858582).cgColor
        case (.cancel, _, _): NSColor(hex: 0x71716E).cgColor
        case (.stop, true, _): NSColor(hex: 0xD2D2CF).cgColor
        case (.stop, _, true): NSColor(hex: 0xEDEDEB).cgColor
        case (.stop, _, _): NSColor(hex: 0xFCFCFB).cgColor
        }
    }

    // MARK: Animation plumbing

    private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    /// Sets the model value and, unless `timing` is `.none`, animates to it from wherever the layer is on screen.
    private func set(_ layer: CALayer, _ keyPath: String, _ value: Any, _ timing: Timing) {
        let from = layer.presentation()?.value(forKeyPath: keyPath) ?? layer.value(forKeyPath: keyPath)
        withoutActions { layer.setValue(value, forKeyPath: keyPath) }
        let animation: CABasicAnimation
        switch timing {
        case .none:
            layer.removeAnimation(forKey: keyPath)
            return
        case .spring:
            // Critically damped with a 55 ms time constant, as the prototype's width and height tween: about 95
            // percent there at 165 ms and no overshoot.
            let spring = CASpringAnimation(keyPath: keyPath)
            spring.mass = 1
            spring.stiffness = 331
            spring.damping = 36.4
            spring.duration = spring.settlingDuration
            animation = spring
        case .ease(let duration, let delay):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.beginTime = delay > 0 ? layer.convertTime(CACurrentMediaTime(), from: nil) + delay : 0
            animation.fillMode = .backwards
            animation.timingFunction = Self.easeOutCubic
        case .easeIn(let duration):
            animation = CABasicAnimation(keyPath: keyPath)
            animation.duration = duration
            animation.timingFunction = Self.easeInCubic
        }
        animation.fromValue = from
        animation.toValue = value
        layer.add(animation, forKey: keyPath)
    }

    // MARK: Modes

    private func apply(_ new: ClassicPillLayout.Mode) {
        let old = mode
        mode = new
        let moving = presented && !reduceMotion
        // Content waits 70 ms so the pill has grown first, then fades in over 120 ms; what leaves fades out in 50 ms.
        let fadeIn: Timing = presented ? .ease(reduceMotion ? 0.15 : 0.12, delay: reduceMotion ? 0 : 0.07) : .none
        let fadeOut: Timing = presented ? .ease(reduceMotion ? 0.15 : 0.05) : .none
        place(
            width: ClassicPillLayout.capsuleWidth(new, scale: scale, metrics: metrics),
            height: ClassicPillLayout.capsuleHeight(new, metrics: metrics),
            timing: moving ? .spring : .none
        )

        let barsOpacity: Float
        switch new {
        case .hold, .locked: barsOpacity = 1
        case .processing: barsOpacity = 1
        case .message: barsOpacity = 0
        }
        set(barsLayer, "opacity", barsOpacity, barsOpacity > 0 ? fadeIn : fadeOut)
        let controlsIn = new == .locked
        for disc in discs.values {
            set(disc.group, "opacity", controlsIn ? Float(1) : 0, controlsIn ? (old != .locked ? fadeIn : .none) : fadeOut)
        }
        var isMessage = false
        if case .message = new { isMessage = true }
        set(textGroup, "opacity", isMessage ? Float(1) : 0, isMessage ? fadeIn : fadeOut)
        layoutBars()
        layoutText()
    }

    func showRecording(locked: Bool) {
        isLocked = locked
        apply(locked ? .locked : .hold)
    }

    func beginProcessing() {
        isLocked = false
        apply(.processing)
    }

    func showMessage(_ message: PillMessage, overRecording: Bool) {
        if !overRecording { isLocked = false }
        self.message = message
        messageOverRecording = overRecording
        block = ClassicPillLayout.messageBlock(
            headline: message.headline, detail: message.detail,
            headlineLineHeight: Typography.lineHeight(typography.font(.pillMessage, scale: k)),
            detailLineHeight: Typography.lineHeight(typography.font(.pillDetail, scale: k)), scale: scale, metrics: metrics
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
        let next = (0..<BarModel.barCount).map {
            ClassicPillLayout.barHeight(fraction: $0 < fractions.count ? fractions[$0] : 0, scale: scale, metrics: metrics)
        }
        guard next != heights else { return }
        heights = next
        layoutBars()
    }

    func updateProcessing(time: TimeInterval) {
        guard mode == .processing else { return }
        let next = ClassicPillLayout.processingFractions(time: time, count: BarModel.barCount)
            .map { ClassicPillLayout.barHeight(fraction: $0, scale: scale, metrics: metrics) }
        guard next != heights else { return }
        heights = next
        layoutBars()
    }

    func setElapsed(_ seconds: TimeInterval?) {}
    func setMessageOffset(_ offset: Int) {}

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
            set(disc.disc, "fillColor", Self.discColor(control, hovered: hovered == control, pressed: down), .ease(0.1))
            set(disc.group, "transform", CATransform3DMakeScale(down ? 0.92 : 1, down ? 0.92 : 1, 1), .ease(0.1))
        }
    }

    // MARK: Show and hide

    /// Scale about the pill's middle plus a vertical offset, for the container.
    private func pillTransform(scale s: CGFloat, drop: CGFloat) -> CATransform3D {
        let pill = capsule(width: width, height: height)
        let dx = (1 - s) * (pill.midX - bounds.midX)
        let dy = (1 - s) * (pill.midY - bounds.midY) - drop
        return CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s, s, 1)
    }

    /// 260 ms ease-out: fades in, grows from 90 percent and rises 5 pt. Fade only under Reduce Motion.
    func appear(reduceMotion: Bool) {
        presented = true
        withoutActions {
            container.opacity = 0
            container.transform = reduceMotion ? CATransform3DIdentity : pillTransform(scale: Self.appearScale, drop: Self.travel * k)
            barsLayer.opacity = 0
            textGroup.opacity = 0
            discs.values.forEach { $0.group.opacity = 0 }
        }
        place(width: metrics.dotWidth, timing: .none)
        let timing: Timing = .ease(reduceMotion ? 0.15 : 0.26)
        set(container, "opacity", Float(1), timing)
        set(container, "transform", CATransform3DIdentity, reduceMotion ? .none : timing)
    }

    /// 160 ms ease-in: fades, shrinks to 90 percent and drops 5 pt.
    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        presented = false
        CATransaction.begin()
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        let duration: TimeInterval = reduceMotion ? 0.12 : 0.16
        set(container, "opacity", Float(0), .easeIn(duration))
        if !reduceMotion {
            set(container, "transform", pillTransform(scale: Self.appearScale, drop: Self.travel * k), .easeIn(duration))
        }
        CATransaction.commit()
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
