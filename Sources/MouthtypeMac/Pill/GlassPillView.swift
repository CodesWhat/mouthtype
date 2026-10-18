import AppKit
import QuartzCore

/// What the Glass pill asks of the system, so a test can stand in for it.
@MainActor
struct GlassPillEnvironment {
    var materialAvailable: () -> Bool
    var reduceTransparency: () -> Bool
    /// The wallpaper behind the pill's region on `view`'s screen, nil when it can't be read.
    var backdrop: (NSView) -> GlassPillPolicy.Backdrop?

    static let system = GlassPillEnvironment(
        materialAvailable: { NSClassFromString("NSGlassEffectView") != nil },
        reduceTransparency: { NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency },
        backdrop: { view in
            guard let window = view.window, let screen = window.screen else { return nil }
            let region = window.convertToScreen(view.convert(view.bounds, to: nil))
            return GlassBackdropSampler.sample(screen: screen, region: region)
        }
    )
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

    var pillScale: PillScale { classic.pillScale }
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
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        if let transparencyObserver { NSWorkspace.shared.notificationCenter.removeObserver(transparencyObserver) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    // MARK: Material

    /// Samples the wallpaper once and decides again.
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
        glass.cornerRadius = min(rect.height, ClassicPillLayout.Metrics(classic.pillScale).height) / 2
        guard animated else {
            glass.frame = rect
            return
        }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.165
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            glass.animator().frame = rect
        }
    }

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
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.15 : 0.26
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.215, 0.61, 0.355, 1)
            glass.animator().alphaValue = 1
        }
    }

    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = reduceMotion ? 0.12 : 0.16
            context.timingFunction = CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19)
            glass.animator().alphaValue = 0
        }
        classic.disappear(reduceMotion: reduceMotion, completion: completion)
    }
}
