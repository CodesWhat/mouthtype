import AppKit
import QuartzCore
import SwiftUI

/// What the Appearance preview animates against. Light and Dark are the two desktops Glass has to be judged over.
enum PreviewWallpaper: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var title: String {
        switch self {
        case .light: "Light"
        case .dark: "Dark"
        }
    }
    /// The appearance a pill over this swatch resolves its palette from.
    var appearance: NSAppearance? {
        switch self {
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }

    /// The caption sits on the swatch, so it flips with it.
    var captionColor: Color {
        switch self {
        case .light: Color.black.opacity(0.65)
        case .dark: .white.opacity(0.8)
        }
    }
}

/// The two drawn swatches as pixels: two soft radial washes over a diagonal base, light or dark. Drawn once with Core
/// Graphics so the stage can show them behind the glass and the same pixels can be analysed by the real policy.
enum PreviewSwatch {
    private struct Palette {
        var base: (UInt32, UInt32)
        var cool: UInt32, coolAlpha: CGFloat
        var warm: UInt32, warmAlpha: CGFloat
    }

    private static func palette(_ wallpaper: PreviewWallpaper) -> Palette {
        switch wallpaper {
        case .light: Palette(base: (0xE6ECF5, 0xC9D6E8), cool: 0xFFFFFF, coolAlpha: 0.9, warm: 0xF3C9B8, warmAlpha: 0.8)
        case .dark: Palette(base: (0x3B4A6B, 0x1D2436), cool: 0x8FA5C8, coolAlpha: 1, warm: 0xC9A6A0, warmAlpha: 0.9)
        }
    }

    private static func colour(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
        CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }

    /// The swatch at `size` points, top-left pixel origin.
    static func image(_ wallpaper: PreviewWallpaper, size: CGSize, scale: CGFloat = 2) -> CGImage? {
        let width = max(1, Int((size.width * scale).rounded())), height = max(1, Int((size.height * scale).rounded()))
        let space = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: scale, y: scale)
        let w = size.width, h = size.height
        let palette = palette(wallpaper)
        // The board's unit points are y-down; Core Graphics here is y-up.
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: w * x, y: h * (1 - y)) }
        if let base = CGGradient(colorsSpace: space, colors: [colour(palette.base.0), colour(palette.base.1)] as CFArray, locations: [0, 1]) {
            context.drawLinearGradient(base, start: point(0.3, 0), end: point(0.7, 1), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
        }
        for (centre, radius, hex, alpha) in [(point(0.15, 0.1), CGFloat(260), palette.cool, palette.coolAlpha),
                                             (point(0.85, 0.8), CGFloat(220), palette.warm, palette.warmAlpha)] {
            guard let wash = CGGradient(colorsSpace: space, colors: [colour(hex, alpha), colour(hex, 0)] as CFArray, locations: [0, 1]) else { continue }
            context.drawRadialGradient(wash, startCenter: centre, startRadius: 0, endCenter: centre, endRadius: radius, options: [])
        }
        return context.makeImage()
    }

    /// What the real policy measures of the swatch behind `region` (stage coordinates, y up, in a swatch of `size`).
    static func backdrop(of wallpaper: PreviewWallpaper, size: CGSize, region: CGRect) -> GlassPillPolicy.Backdrop? {
        guard let image = image(wallpaper, size: size) else { return nil }
        return backdrop(in: image, size: size, region: region)
    }

    static func backdrop(in image: CGImage, size: CGSize, region: CGRect) -> GlassPillPolicy.Backdrop? {
        let sx = CGFloat(image.width) / size.width, sy = CGFloat(image.height) / size.height
        let pixels = CGRect(x: region.minX * sx, y: (size.height - region.maxY) * sy, width: region.width * sx, height: region.height * sy)
            .intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height)).integral
        guard pixels.width >= 1, pixels.height >= 1, let part = image.cropping(to: pixels) else { return nil }
        return GlassBackdropSampler.backdrop(of: part)
    }
}

/// A synthetic voice for the preview: a slow phrase envelope with each bar on its own wobble, shaped by the same fixed
/// weights the real meter uses so the middle bars run tallest. Pure, so the shape is testable.
enum PreviewLevel {
    /// The pose shown when nothing is animating (Reduce Motion, or the window is away).
    static let still: [Float] = [0.2, 0.4, 0.6, 0.8, 0.5, 0.35, 0.65, 0.3, 0.2, 0.1]

    static func fractions(at time: TimeInterval) -> [Float] {
        let phrase = Float(0.45 + 0.55 * abs(sin(time * 1.9) * cos(time * 0.55 + 0.6)))
        return BarModel.weights.enumerated().map { index, weight in
            let wobble = Float(0.55 + 0.45 * sin(time * 8.5 + Double(index) * 0.93))
            return min(1, max(0, phrase * weight * wobble * 1.15))
        }
    }
}

/// Whether the preview may run, from everything that can switch it off. Kept apart from AppKit so every combination is a
/// plain test.
struct PreviewActivity: Equatable {
    var pageVisible = true
    var windowOnscreen = false
    var reduceMotion = false

    var animates: Bool { pageVisible && windowOnscreen && !reduceMotion }
}

/// How the preview canvas fits a card: pills render at their own size on a fixed canvas and the canvas shrinks, never
/// grows, when the card is narrower than it.
enum PreviewFit {
    static let canvas = CGSize(width: 440, height: 120)

    static func scale(availableWidth: CGFloat) -> CGFloat {
        guard availableWidth > 0 else { return 1 }
        return min(1, availableWidth / canvas.width)
    }

    /// The line under the preview: the size shown, and a note when it is scaled down to fit.
    static func caption(size: PillSize, scale: CGFloat) -> String {
        var text: String
        switch size {
        case .automatic: text = "Automatic shown at Standard. It picks Large on wide screens."
        case .standard: text = "Standard size."
        case .large: text = "Large size, twice Standard."
        }
        if scale < 0.995 { text += " Shown at \(Int((scale * 100).rounded()))% to fit."}
        return text
    }
}

/// What the preview is showing behind the pill and what Glass decided over it, for the caption.
struct PreviewStatus: Equatable {
    enum Source: Equatable { case light, dark }
    var source: Source
    /// The Glass decision; nil for every other style.
    var decision: GlassPillPolicy.Decision?
    var backdrop: GlassPillPolicy.Backdrop?
}

enum GlassPreviewCaption {
    /// The line under the size caption, or nil when there is nothing to say (a non-Glass style over a swatch).
    static func text(_ status: PreviewStatus?) -> String? {
        guard let status else { return nil }
        let over: String
        switch status.source {
        case .light: over = "over the Light swatch"
        case .dark: over = "over the Dark swatch"
        }
        var parts = [String]()
        if let decision = status.decision {
            switch decision {
            case .glass(.clear): parts.append("Glass · clear \(over)")
            case .glass(.smoked): parts.append("Glass · smoked \(over)")
            case .solid(.reduceTransparency): parts.append("Glass · solid: Reduce Transparency")
            case .solid(.materialUnavailable): parts.append("Glass · solid: material unavailable")
            }
        }
        return parts.isEmpty ? nil : parts.joined(separator: ". ").replacingOccurrences(of: "..", with: ".")
    }
}

/// Holds the backdrop the preview's Glass pill reads, so the stage can change it and have the pill decide again.
@MainActor final class PreviewBackdropSource {
    var backdrop: GlassPillPolicy.Backdrop?
}

/// The live pill in the Appearance preview. It owns a real `PillSkinView` and, while it is allowed to, drives it from a
/// 30 fps display link with a synthetic level. Every way the preview can stop mattering (window closed, minimised,
/// hidden or covered, page left, Reduce Motion) lands in `refresh()`, which drops the link and freezes the layers, so
/// nothing runs in the background.
@MainActor
final class PillPreviewStage: NSView {
    /// How the stage asks whether its window is on screen. Tests replace it; a hosted-but-never-shown window is not.
    static var windowOnscreen: (NSWindow?) -> Bool = { window in
        guard let window else { return false }
        return window.isVisible && window.occlusionState.contains(.visible) && !window.isMiniaturized
    }
    static var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    /// The system answers the preview's Glass pill asks (material, Reduce Transparency); only its backdrop is replaced.
    static var systemEnvironment: GlassPillEnvironment = .system
    static var backdropCache: GlassBackdropCache = .shared
    private static let bottomInset: CGFloat = 10
    private static let defaultSize = CGSize(width: PreviewFit.canvas.width, height: 156)

    private let canvas = NSView(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
    private(set) var skin: (any PillSkinView)?
    private(set) var kind: PillSkinKind?
    private(set) var scale: PillScale?
    private(set) var readout: PillReadoutColour?
    private(set) var wallpaper: PreviewWallpaper?
    private let snapshot = NSImageView()
    private let backdropView = NSView()
    private let backdropSource = PreviewBackdropSource()
    private var laidOutSize = CGSize.zero
    private var lastDecision: GlassPillPolicy.Decision?
    private var lastAppearance: PreviewWallpaper?
    private(set) var status: PreviewStatus?
    var onStatusChange: ((PreviewStatus) -> Void)?
    /// The backdrop the preview's Glass pill is deciding against.
    var glassBackdrop: GlassPillPolicy.Backdrop? { backdropSource.backdrop }

    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var frozen = false
    /// True from building a skin until its entrance has played. The entrance waits for the stage to be on screen, so the
    /// user sees it, and a layer frozen offscreen never holds it half done.
    private var entrancePending = false
    private var observers: [NSObjectProtocol] = []
    private(set) var framesDriven = 0
    var pageVisible = true { didSet { refresh() } }

    var isAnimating: Bool { link != nil }
    private(set) var activity = PreviewActivity()
    /// True while a settled still stands in for the live skin.
    var showsSnapshot: Bool { !snapshot.isHidden }

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear
        backdropView.wantsLayer = true
        backdropView.layer?.contentsGravity = .resize
        backdropView.layer?.contentsScale = 2
        addSubview(backdropView)
        addSubview(canvas)
        canvas.wantsLayer = true
        snapshot.imageScaling = .scaleProportionallyUpOrDown
        snapshot.setAccessibilityElement(false)
        addSubview(snapshot)
        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } })
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    isolated deinit {
        link?.invalidate()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        for observer in observers { NotificationCenter.default.removeObserver(observer); NSWorkspace.shared.notificationCenter.removeObserver(observer) }
    }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }
    override var intrinsicContentSize: NSSize { PreviewFit.canvas }

    // MARK: Content

    /// Rebuilds the pill when the style, size, readout colour or swatch differs from what is showing. The swatch is a
    /// layer behind the pill, so the real Glass material refracts it, and the same policy the real pill uses decides
    /// against the swatch's own pixels.
    func configure(kind: PillSkinKind, scale: PillScale, readout: PillReadoutColour, wallpaper: PreviewWallpaper) {
        guard kind != self.kind || scale != self.scale || wallpaper != self.wallpaper || (kind == .hifi && readout != self.readout) else { return }
        self.wallpaper = wallpaper
        let frame = skinFrame(kind: kind, scale: scale)
        skin?.removeFromSuperview()
        guard let next = try? PillSkinFactory.make(kind, frame: frame, scale: scale, readout: readout, glassEnvironment: glassEnvironment) else { skin = nil; return }
        skin = next
        self.kind = kind
        self.scale = scale
        self.readout = readout
        canvas.addSubview(next)
        frozen = false
        next.layer?.speed = 1
        entrancePending = true
        started = CACurrentMediaTime()
        applyBackdrop(force: true)
        refresh()
    }

    private lazy var glassEnvironment = GlassPillEnvironment(
        materialAvailable: Self.systemEnvironment.materialAvailable,
        reduceTransparency: Self.systemEnvironment.reduceTransparency,
        backdrop: { [source = backdropSource] _ in source.backdrop },
        prewarm: {}
    )

    private func skinFrame(kind: PillSkinKind, scale: PillScale) -> NSRect {
        let size = PreviewFit.canvas
        let height = (kind.pillHeight * scale.factor) + 2 * PillGeometry.verticalMargin
        return NSRect(x: 0, y: ((size.height - height) / 2).rounded(), width: size.width, height: height)
    }

    private var swatchSize: CGSize { bounds.width > 0 && bounds.height > 0 ? bounds.size : Self.defaultSize }

    /// The held pill body in the stage's coordinates (y up), which is where the swatch is measured.
    private func bodyRegionInStage() -> CGRect {
        guard let kind, let scale else { return .zero }
        let frame = skinFrame(kind: kind, scale: scale)
        let local = GlassPillView.heldBodyRegion(bounds: frame.size, size: scale, backing: window?.backingScaleFactor ?? 2).offsetBy(dx: frame.minX, dy: frame.minY)
        let size = swatchSize
        let fit = PreviewFit.scale(availableWidth: size.width)
        let origin = canvasOrigin(in: size, fit: fit)
        return CGRect(x: origin.x + local.minX * fit, y: origin.y + local.minY * fit, width: local.width * fit, height: local.height * fit)
    }

    private func canvasOrigin(in size: CGSize, fit: CGFloat) -> CGPoint {
        let canvas = CGSize(width: PreviewFit.canvas.width * fit, height: PreviewFit.canvas.height * fit)
        let usableHeight = max(0, size.height - Self.bottomInset)
        return CGPoint(x: ((size.width - canvas.width) / 2).rounded(), y: (Self.bottomInset + (usableHeight - canvas.height) / 2).rounded())
    }

    // MARK: Backdrop

    /// Puts the swatch behind the pill, hands the pill the backdrop the real analysis gives it, and publishes the result.
    /// The snapshot is redrawn when the decision or the swatch's appearance changed, or when `force`d.
    private func applyBackdrop(force: Bool = false) {
        guard let kind, let scale else { return }
        let effective = wallpaper ?? .dark
        canvas.appearance = effective.appearance
        snapshot.appearance = effective.appearance
        let size = swatchSize
        let image = PreviewSwatch.image(effective, size: size)
        backdropView.layer?.contents = image
        backdropSource.backdrop = image.flatMap { PreviewSwatch.backdrop(in: $0, size: size, region: bodyRegionInStage()) }
        let source: PreviewStatus.Source = effective == .light ? .light : .dark
        let glass = skin as? GlassPillView
        glass?.refreshBackdrop()
        let decision = glass?.decision
        if force || decision != lastDecision || effective != lastAppearance {
            lastDecision = decision
            lastAppearance = effective
            snapshot.image = SettingsPillImage.make(skin: kind, size: scale == .large ? .large : .standard, readout: readout ?? .default,
                                                    wallpaper: effective, glassEnvironment: glassEnvironment)
        }
        let next = PreviewStatus(source: source, decision: decision, backdrop: backdropSource.backdrop)
        if next != status {
            status = next
            onStatusChange?(next)
        }
    }

    override func layout() {
        super.layout()
        let fit = PreviewFit.scale(availableWidth: bounds.width)
        let size = CGSize(width: PreviewFit.canvas.width * fit, height: PreviewFit.canvas.height * fit)
        let origin = canvasOrigin(in: bounds.size, fit: fit)
        canvas.frame = NSRect(origin: origin, size: size)
        canvas.bounds = NSRect(origin: .zero, size: PreviewFit.canvas)
        snapshot.frame = canvas.frame
        backdropView.frame = bounds
        if bounds.size != laidOutSize {
            laidOutSize = bounds.size
            applyBackdrop()
        }
    }

    // MARK: Activity

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
        if let window {
            let center = NotificationCenter.default
            for name in [NSWindow.willCloseNotification, NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                         NSWindow.didDeminiaturizeNotification, NSWindow.didChangeScreenNotification, NSWindow.didBecomeKeyNotification,
                         NSWindow.didExposeNotification] {
                windowObservers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        // willClose arrives while the window still reports visible.
                        self?.closing = name == NSWindow.willCloseNotification
                        self?.refresh()
                    }
                })
            }
            closing = false
        }
        refresh()
    }

    private var windowObservers: [NSObjectProtocol] = []
    private var closing = false

    override func viewDidHide() { super.viewDidHide(); refresh() }
    override func viewDidUnhide() { super.viewDidUnhide(); refresh() }

    /// Stops all motion and unhooks from the window. Called when SwiftUI drops the preview (page change).
    func shutDown() {
        pageVisible = false
        for observer in windowObservers { NotificationCenter.default.removeObserver(observer) }
        windowObservers = []
    }

    func refresh() {
        activity = PreviewActivity(
            pageVisible: pageVisible,
            windowOnscreen: !closing && !isHiddenOrHasHiddenAncestor && Self.windowOnscreen(window),
            reduceMotion: Self.reduceMotion()
        )
        if activity.animates { playEntrance(); start() } else { stop() }
        // Only a stage that is animating shows the live skin. A window that has never been shown cannot run the entrance
        // animations, and Reduce Motion wants a settled pose, so both show the still instead.
        let still = !activity.animates
        snapshot.isHidden = !still
        canvas.isHidden = still
    }

    /// The same order `PillController` uses: the pill appears first, then the recording state arrives. Classic's `appear`
    /// places the pill as a dot, so a state set before it is wiped and the width never springs out.
    private func playEntrance() {
        guard entrancePending, let skin else { return }
        entrancePending = false
        skin.appear(reduceMotion: Self.reduceMotion())
        skin.showRecording(locked: false)
        skin.showFractions(PreviewLevel.still)
        skin.setElapsed(0)
        started = CACurrentMediaTime()
    }

    private func start() {
        guard link == nil else { return }
        thaw()
        let link = displayLink(target: PreviewLinkTarget(owner: self), selector: #selector(PreviewLinkTarget.tick(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 20, maximum: 30, preferred: 30)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stop() {
        link?.invalidate()
        link = nil
        freeze()
    }

    /// Halts the lamp's repeating animation as well, which the display link does not drive.
    private func freeze() {
        guard !frozen, let layer = skin?.layer else { return }
        let time = layer.convertTime(CACurrentMediaTime(), from: nil)
        layer.speed = 0
        layer.timeOffset = time
        frozen = true
    }

    private func thaw() {
        guard frozen, let layer = skin?.layer else { return }
        let paused = layer.timeOffset
        layer.speed = 1
        layer.timeOffset = 0
        layer.beginTime = 0
        layer.beginTime = layer.convertTime(CACurrentMediaTime(), from: nil) - paused
        frozen = false
    }

    fileprivate func tick(_ link: CADisplayLink) {
        guard let skin else { return }
        framesDriven += 1
        let elapsed = max(0, link.targetTimestamp - started)
        skin.showFractions(PreviewLevel.fractions(at: elapsed))
        skin.setElapsed(elapsed.truncatingRemainder(dividingBy: 600))
    }
}

private final class PreviewLinkTarget: NSObject {
    weak var owner: PillPreviewStage?
    init(owner: PillPreviewStage) { self.owner = owner }
    @MainActor @objc func tick(_ link: CADisplayLink) { owner?.tick(link) }
}

/// The stage in SwiftUI. SwiftUI drops it with the page, and `dismantleNSView` is what stops it then.
struct PillPreviewStageView: NSViewRepresentable {
    let kind: PillSkinKind
    let size: PillSize
    let readout: PillReadoutColour
    let wallpaper: PreviewWallpaper
    var onStatus: (PreviewStatus) -> Void = { _ in }

    func makeNSView(context: Context) -> PillPreviewStage { PillPreviewStage() }

    func updateNSView(_ stage: PillPreviewStage, context: Context) {
        stage.onStatusChange = onStatus
        stage.configure(kind: kind, scale: size.resolved(visibleWidth: 0), readout: readout, wallpaper: wallpaper)
        if let status = stage.status { onStatus(status) }
        stage.pageVisible = true
    }

    static func dismantleNSView(_ stage: PillPreviewStage, coordinator: ()) { stage.shutDown() }
}
