import AppKit
import QuartzCore

/// What the Glass pill asks of the system, so a test can stand in for it.
@MainActor
struct GlassPillEnvironment {
    var materialAvailable: () -> Bool
    var reduceTransparency: () -> Bool
    /// The wallpaper behind the pill on `view`'s screen, nil when it can't be read or isn't measured yet. It must
    /// never decode on the calling thread: it runs between the hotkey and the pill appearing.
    var backdrop: (NSView) -> GlassPillPolicy.Backdrop?
    /// Measures the wallpaper in the background ahead of the first press.
    var prewarm: () -> Void = {}

    static let system = system(cache: .shared)

    /// The production wiring over `cache`; `.system` uses the shared one.
    static func system(cache: GlassBackdropCache) -> GlassPillEnvironment { GlassPillEnvironment(
        materialAvailable: { NSClassFromString("NSGlassEffectView") != nil },
        reduceTransparency: { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
        backdrop: { view in
            guard let window = view.window, let screen = window.screen else { return nil }
            let local = (view as? GlassPillView)?.sampleRegion ?? view.bounds
            let region = window.convertToScreen(view.convert(local, to: nil))
            guard case .ready(let backdrop) = cache.lookup(screen: screen, region: region) else { return nil }
            return backdrop
        },
        prewarm: { cache.prewarmAll() }
    ) }
}

/// The glass pill: the Classic pill's geometry, bars and controls over the system glass material (clear over light
/// content, smoked over dark) with a specular edge. It falls back to the solid Classic body when the material is
/// unavailable, when Reduce Transparency is on, or when the wallpaper behind it fails a contrast check; the check
/// runs when the pill appears, never per frame. The Stop control stays solid in every case.
@MainActor
final class GlassPillView: NSView, PillSkinView {
    static let clearInk = NSColor(hex: 0x1D1D1F)
    static let clearErrorInk = NSColor(hex: 0xD70015)

    private let classic: ClassicPillView
    private let glass = NSGlassEffectView()
    private let environment: GlassPillEnvironment
    private var transparencyObserver: NSObjectProtocol?
    /// The last sampled wallpaper, kept so a Reduce Transparency change can decide again without sampling.
    private var backdrop: GlassPillPolicy.Backdrop?
    private(set) var decision: GlassPillPolicy.Decision = .solid(.materialUnavailable)
    /// The capsule as last placed, in this view's coordinates.
    private(set) var bodyRect = CGRect.zero

    /// The pill body at its held width in `bounds`, which is where the wallpaper is sampled: the panel is far larger
    /// than the capsule, and a message's width and height would not be known until after the decision.
    static func heldBodyRegion(bounds: CGSize, size: PillScale, backing: CGFloat) -> CGRect {
        let metrics = ClassicPillLayout.Metrics(size)
        return ClassicPillLayout.capsuleFrame(
            width: ClassicPillLayout.holdWidth(scale: backing, metrics: metrics), height: metrics.height, bounds: bounds,
            bottomMargin: PillGeometry.verticalMargin, scale: backing
        )
    }

    /// The held pill body in this view's coordinates.
    var sampleRegion: CGRect {
        Self.heldBodyRegion(bounds: bounds.size, size: classic.pillScale, backing: window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2)
    }

    /// Replaces the system Reduce Motion setting for the body's own motion; tests set it.
    var reduceMotionOverride: Bool? {
        get { classic.reduceMotionOverride }
        set { classic.reduceMotionOverride = newValue }
    }
    var pillScale: PillScale { classic.pillScale }
    var capsuleWidth: CGFloat { classic.capsuleWidth }
    /// True while the system material is showing, false on the solid Classic body.
    var showsMaterial: Bool { !glass.isHidden }
    var bodyIsGlass: Bool { classic.glassBody }
    var isLocked: Bool { classic.isLocked }
    var messageScrollDistance: Int { classic.messageScrollDistance }
    var controlFrames: [PillControl: CGRect] { classic.controlFrames }
    var messageLines: [ClassicPillLayout.MessageLine] { classic.messageLines }
    var messageSize: CGSize { classic.messageSize }

    init(frame: NSRect, size: PillScale = .standard, environment: GlassPillEnvironment = .system) {
        self.environment = environment
        classic = ClassicPillView(frame: NSRect(origin: .zero, size: frame.size), size: size)
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        glass.wantsLayer = true
        glass.alphaValue = 0
        glass.isHidden = true
        addSubview(glass)
        classic.frame = bounds
        classic.autoresizingMask = [.width, .height]
        addSubview(classic)
        classic.onBodyPlaced = { [weak self] rect, animated in self?.placeGlass(rect, animated: animated) }
        transparencyObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.reevaluate() } }
        reevaluate()
        environment.prewarm()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let transparencyObserver { NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Material

    /// Reads the cached wallpaper sample (never decoding here) and decides again; an unmeasured wallpaper gets smoked glass.
    func refreshBackdrop() {
        backdrop = environment.backdrop(self)
        reevaluate()
    }

    private func reevaluate() {
        let next = GlassPillPolicy.decide(
            materialAvailable: environment.materialAvailable(), reduceTransparency: environment.reduceTransparency(),
            backdrop: backdrop
        )
        decision = next
        classic.useGlassBody(next.usesMaterial)
        switch next {
        case .glass(.clear):
            glass.style = .clear
            glass.tintColor = NSColor.white.withAlphaComponent(0.12)
            classic.setInk(Self.clearInk, error: Self.clearErrorInk)
        case .glass(.smoked):
            glass.style = .regular
            glass.tintColor = NSColor(srgbRed: 18 / 255, green: 18 / 255, blue: 22 / 255, alpha: 0.55)
            classic.setInk(ClassicPillView.ink, error: ClassicPillView.errorInk)
        case .solid:
            classic.setInk(ClassicPillView.ink, error: ClassicPillView.errorInk)
        }
        glass.isHidden = !next.usesMaterial
    }

    private func placeGlass(_ rect: CGRect, animated: Bool) {
        bodyRect = rect
        glass.cornerRadius = min(rect.height, ClassicPillLayout.Metrics(classic.pillScale).height) / 2
        guard let layer = glass.layer else {
            glass.frame = rect
            return
        }
        PillMotion.withoutActions { glass.frame = rect }
        guard animated else {
            layer.removeAnimation(forKey: "bounds")
            layer.removeAnimation(forKey: "position")
            return
        }
        // The body's own spring, so the material grows with the capsule instead of trailing it.
        let anchor = layer.anchorPoint
        PillMotion.set(layer, "bounds", NSValue(rect: CGRect(origin: .zero, size: rect.size)), .spring)
        PillMotion.set(
            layer, "position",
            NSValue(point: CGPoint(x: rect.minX + anchor.x * rect.width, y: rect.minY + anchor.y * rect.height)), .spring
        )
    }

    /// Scale about the glass's middle plus a drop, as the Classic container does for the capsule. A layer scales about
    /// its anchor point, so the shift between the anchor and the middle is added back.
    private func glassTransform(scale s: CGFloat, drop: CGFloat) -> NSValue {
        guard let layer = glass.layer else { return NSValue(caTransform3D: CATransform3DIdentity) }
        let size = layer.bounds.size
        let dx = (1 - s) * (0.5 - layer.anchorPoint.x) * size.width
        let dy = (1 - s) * (0.5 - layer.anchorPoint.y) * size.height - drop
        return NSValue(caTransform3D: CATransform3DScale(CATransform3DMakeTranslation(dx, dy, 0), s, s, 1))
    }

    var glassLayer: CALayer? { glass.layer }

    // MARK: PillSkinView

    func showRecording(locked: Bool) { classic.showRecording(locked: locked) }
    func beginProcessing() { classic.beginProcessing() }
    func showMessage(_ message: PillMessage, overRecording: Bool) { classic.showMessage(message, overRecording: overRecording) }
    func applyTypography(_ typography: Typography) { classic.applyTypography(typography) }
    func showFractions(_ fractions: [Float]) { classic.showFractions(fractions) }
    func updateProcessing(time: TimeInterval) { classic.updateProcessing(time: time) }
    func setElapsed(_ seconds: TimeInterval?) { classic.setElapsed(seconds) }
    func setMessageOffset(_ offset: Int) { classic.setMessageOffset(offset) }
    func setHovered(_ control: PillControl?) { classic.setHovered(control) }
    func setPressed(_ control: PillControl?) { classic.setPressed(control) }

    func appear(reduceMotion: Bool) {
        refreshBackdrop()
        classic.appear(reduceMotion: reduceMotion)
        if let layer = glass.layer {
            let identity = NSValue(caTransform3D: CATransform3DIdentity)
            PillMotion.withoutActions {
                layer.transform = reduceMotion ? identity.caTransform3DValue : glassTransform(scale: ClassicPillView.appearScale, drop: ClassicPillView.travel * classic.pillScale.factor).caTransform3DValue
            }
            PillMotion.set(layer, "transform", identity, reduceMotion ? .none : .ease(0.26))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            glass.animator().alphaValue = 1
        }
    }

    /// The system material only renders in a window, and the classic view lives in a subview with no layer of its own to
    /// render offscreen. This draws a flat tint in the material's place, so it approximates the glass and is not it.
    func renderOffscreen(in context: CGContext) {
        if case .glass(let variant) = decision {
            context.saveGState()
            let radius = ClassicPillLayout.Metrics(classic.pillScale).cornerRadius
            context.addPath(CGPath(roundedRect: bodyRect, cornerWidth: radius, cornerHeight: radius, transform: nil))
            context.clip()
            switch variant {
            case .clear: context.setFillColor(NSColor.white.withAlphaComponent(0.36).cgColor)
            case .smoked: context.setFillColor(NSColor(srgbRed: 34 / 255, green: 34 / 255, blue: 40 / 255, alpha: 0.45).cgColor)
            }
            context.fill(bodyRect)
            context.restoreGState()
        }
        classic.layer?.render(in: context)
    }

    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        if !reduceMotion, let layer = glass.layer {
            let drop = ClassicPillView.travel * classic.pillScale.factor
            PillMotion.set(layer, "transform", glassTransform(scale: ClassicPillView.appearScale, drop: drop), .easeIn(0.16))
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19)
            glass.animator().alphaValue = 0
        }
        classic.disappear(reduceMotion: reduceMotion, completion: completion)
    }
}
