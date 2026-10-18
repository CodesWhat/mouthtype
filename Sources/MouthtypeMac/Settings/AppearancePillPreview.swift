import AppKit
import QuartzCore
import SwiftUI

/// What the Appearance preview animates against. Light and Dark are the two desktops Glass has to be judged over.
enum PreviewWallpaper: String, CaseIterable, Identifiable {
    case light, dark

    var id: String { rawValue }
    var title: String { self == .light ? "Light" : "Dark" }
    /// The appearance a pill over this swatch resolves its palette from.
    var appearance: NSAppearance { NSAppearance(named: self == .dark ? .darkAqua : .aqua)! }

    /// The board's swatch: two soft radial washes over a diagonal base, light or dark.
    var base: [Color] {
        switch self {
        case .dark: [Color(red: 0x3B / 255, green: 0x4A / 255, blue: 0x6B / 255), Color(red: 0x1D / 255, green: 0x24 / 255, blue: 0x36 / 255)]
        case .light: [Color(red: 0xE6 / 255, green: 0xEC / 255, blue: 0xF5 / 255), Color(red: 0xC9 / 255, green: 0xD6 / 255, blue: 0xE8 / 255)]
        }
    }
    var coolWash: Color { self == .dark ? Color(red: 0x8F / 255, green: 0xA5 / 255, blue: 0xC8 / 255) : Color(red: 0xFF / 255, green: 0xFF / 255, blue: 0xFF / 255) }
    var warmWash: Color { self == .dark ? Color(red: 0xC9 / 255, green: 0xA6 / 255, blue: 0xA0 / 255) : Color(red: 0xF3 / 255, green: 0xC9 / 255, blue: 0xB8 / 255) }
    /// The caption sits on the swatch, so it flips with it.
    var captionColor: Color { self == .dark ? .white.opacity(0.8) : Color.black.opacity(0.65) }
}

struct PreviewWallpaperView: View {
    let wallpaper: PreviewWallpaper

    var body: some View {
        ZStack {
            LinearGradient(colors: wallpaper.base, startPoint: UnitPoint(x: 0.3, y: 0), endPoint: UnitPoint(x: 0.7, y: 1))
            RadialGradient(colors: [wallpaper.coolWash.opacity(wallpaper == .dark ? 1 : 0.9), .clear], center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 260)
            RadialGradient(colors: [wallpaper.warmWash.opacity(wallpaper == .dark ? 0.9 : 0.8), .clear], center: UnitPoint(x: 0.85, y: 0.8), startRadius: 0, endRadius: 220)
        }
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

    private let canvas = NSView(frame: NSRect(origin: .zero, size: PreviewFit.canvas))
    private(set) var skin: (any PillSkinView)?
    private(set) var kind: PillSkinKind?
    private(set) var scale: PillScale?
    private(set) var readout: PillReadoutColour?
    private(set) var wallpaper: PreviewWallpaper?
    private let snapshot = NSImageView()
    private var link: CADisplayLink?
    private var started: CFTimeInterval = 0
    private var frozen = false
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

    /// Rebuilds the pill when the style, size, readout colour or swatch differs from what is showing. The swatch sets the
    /// appearance the pill resolves its palette from, so Matrix, Minimal and Glass show the mode the swatch stands for.
    func configure(kind: PillSkinKind, scale: PillScale, readout: PillReadoutColour, wallpaper: PreviewWallpaper) {
        guard kind != self.kind || scale != self.scale || wallpaper != self.wallpaper || (kind == .hifi && readout != self.readout) else { return }
        let appearance = wallpaper.appearance
        canvas.appearance = appearance
        snapshot.appearance = appearance
        let size = PreviewFit.canvas
        let height = (kind.pillHeight * scale.factor) + 2 * PillGeometry.verticalMargin
        let frame = NSRect(x: 0, y: ((size.height - height) / 2).rounded(), width: size.width, height: height)
        skin?.removeFromSuperview()
        guard let next = try? PillSkinFactory.make(kind, frame: frame, scale: scale, readout: readout) else { skin = nil; return }
        skin = next
        self.kind = kind
        self.scale = scale
        self.readout = readout
        self.wallpaper = wallpaper
        canvas.addSubview(next)
        frozen = false
        next.layer?.speed = 1
        next.showRecording(locked: false)
        next.showFractions(PreviewLevel.still)
        next.setElapsed(0)
        next.appear(reduceMotion: Self.reduceMotion())
        started = CACurrentMediaTime()
        snapshot.image = SettingsPillImage.make(skin: kind, size: scale == .large ? .large : .standard, readout: readout, wallpaper: wallpaper)
        refresh()
    }

    override func layout() {
        super.layout()
        let fit = PreviewFit.scale(availableWidth: bounds.width)
        let size = CGSize(width: PreviewFit.canvas.width * fit, height: PreviewFit.canvas.height * fit)
        canvas.frame = NSRect(x: ((bounds.width - size.width) / 2).rounded(), y: ((bounds.height - size.height) / 2).rounded(), width: size.width, height: size.height)
        canvas.bounds = NSRect(origin: .zero, size: PreviewFit.canvas)
        snapshot.frame = canvas.frame
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
        if activity.animates { start() } else { stop() }
        // A window that has never been shown cannot run the entrance animations, so it shows a settled still instead.
        let still = !(window?.isVisible ?? false)
        snapshot.isHidden = !still
        canvas.isHidden = still
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

    func makeNSView(context: Context) -> PillPreviewStage { PillPreviewStage() }

    func updateNSView(_ stage: PillPreviewStage, context: Context) {
        stage.configure(kind: kind, scale: size.resolved(visibleWidth: 0), readout: readout, wallpaper: wallpaper)
        stage.pageVisible = true
    }

    static func dismantleNSView(_ stage: PillPreviewStage, coordinator: ()) { stage.shutDown() }
}
