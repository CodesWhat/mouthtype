// Panel set-up adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import QuartzCore

/// A borderless panel that never takes focus, so showing it cannot pull the app forward or move the caret.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating pill: a hi-fi deck with a live level meter and timer while recording, a travelling run of segments
/// while processing, and one line of text for a message. The panel is built once at init and only ordered in and
/// out; the display link runs only while something on screen moves, so nothing runs while idle.
@MainActor
public final class PillController {
    enum State: Equatable {
        case hidden, recording, handsFree, processing, message(String)
    }

    /// Room around the pill for the show and hide travel; whole points at every art scale.
    static let horizontalPadding: CGFloat = 16 * PillView.artScale
    static let pillPadding: CGFloat = 8 * PillView.artScale
    static let panelSize = CGSize(
        width: PillView.pillSize.width + 2 * horizontalPadding, height: PillView.pillSize.height + 2 * pillPadding
    )
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.16
    private static let travel: CGFloat = 6 * PillView.artScale

    private(set) var state: State = .hidden
    let panel: PillPanel
    let view: PillView

    /// Read once per frame while recording. `PillDemo` swaps it for a synthetic curve.
    var levelSource: @MainActor () -> Float

    private var bars = BarModel()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var processingStart: CFTimeInterval = 0
    /// When the current recording began; nil outside a recording and its notices.
    private var recordingStart: CFTimeInterval?
    private var messageStart: CFTimeInterval = 0
    /// Bumped by every state change, so a message timer or a hide completion only acts on its own state.
    private var generation = 0

    public init(level: @escaping @MainActor () -> Float) {
        levelSource = level
        let assets: PillAssets
        do {
            assets = try PillAssets.loadHiFi()
        } catch {
            fatalError("pill resources missing from the bundle: \(error)")
        }
        view = PillView(frame: NSRect(origin: .zero, size: Self.panelSize), assets: assets)
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: Self.panelSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
    }

    public func showRecording() {
        enter(.recording)
        recordingStart = CACurrentMediaTime()
        view.setLocked(false)
        view.setTalkDown(true)
        beginMeter()
    }

    /// The same meter and timer with the padlock and lit caps, for a recording that stays open on its own.
    public func showHandsFree() {
        enter(.handsFree)
        if recordingStart == nil { recordingStart = CACurrentMediaTime() }
        view.setLocked(true)
        view.setTalkDown(false)
        beginMeter()
    }

    /// One line over a hands-free recording, then back to the hands-free pill unless something else took over.
    public func showHandsFreeNotice(_ text: String, duration: TimeInterval = 4) {
        guard state == .handsFree else { return }
        enter(.message(text))
        presentMessage(text, duration: duration) { [weak self] in self?.showHandsFree() }
    }

    public func showProcessing() {
        enter(.processing)
        recordingStart = nil
        view.setLocked(false)
        view.setTalkDown(false)
        view.setLED(false)
        view.setTimer(seconds: nil)
        processingStart = CACurrentMediaTime()
        view.showRun(columns: BarModel.processingColumns(time: 0, columns: BarModel.barCount))
        startLink()
    }

    public func showMessage(_ text: String, duration: TimeInterval = 2.5) {
        enter(.message(text))
        recordingStart = nil
        view.setLocked(false)
        view.setTalkDown(false)
        view.setLED(false)
        view.setTimer(seconds: nil)
        presentMessage(text, duration: duration) { [weak self] in self?.hide() }
    }

    public func hide() {
        guard state != .hidden else { return }
        generation += 1
        state = .hidden
        recordingStart = nil
        stopLink()
        let shown = generation
        animate(visible: false) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private var isShown: Bool { state != .hidden }

    private func beginMeter() {
        bars.reset()
        lastTimestamp = nil
        showMeter(bars.step(level: 0, dt: 0))
        updateChrome(now: CACurrentMediaTime())
        startLink()
    }

    private func showMeter(_ fractions: [Float]) {
        view.showMeter(litCounts: BarModel.litSegments(fractions, segments: BarModel.segmentRows))
    }

    /// Timer and REC lamp, from the recording's own clock.
    private func updateChrome(now: CFTimeInterval) {
        guard let start = recordingStart else { return }
        let elapsed = max(0, now - start)
        view.setTimer(seconds: Int(elapsed))
        view.setLED(PillTimeline.ledOn(elapsed: elapsed, locked: view.isLocked))
    }

    /// Shows `text`, and runs `after` once it has been up for `duration`, or for as long as it takes to scroll through.
    private func presentMessage(_ text: String, duration: TimeInterval, then after: @escaping @MainActor () -> Void) {
        view.showMessage(text)
        messageStart = CACurrentMediaTime()
        let distance = view.messageScrollDistance
        let shownFor = distance > 0 ? max(duration, Marquee.duration(distance: distance) + 0.3) : duration
        if distance > 0 || recordingStart != nil { startLink() } else { stopLink() }
        let shown = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(shownFor))
            guard let self, self.generation == shown else { return }
            after()
        }
    }

    /// Moves to `next`, placing and fading the panel in unless it is already up.
    private func enter(_ next: State) {
        generation += 1
        let wasShown = isShown
        state = next
        guard !wasShown else { return }
        place()
        panel.orderFrontRegardless()
        animate(visible: true, completion: nil)
    }

    private func place() {
        let screens = NSScreen.screens.map { PillPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let origin = PillPlacement.origin(
            pointer: NSEvent.mouseLocation, screens: screens, panelSize: Self.panelSize, pillPadding: Self.pillPadding
        ) else { return }
        panel.setFrameOrigin(CGPoint(x: origin.x.rounded(.down), y: origin.y.rounded(.down)))
    }

    /// A short fade with a few points of upward travel; fade only under Reduce Motion.
    private func animate(visible: Bool, completion: (@MainActor () -> Void)?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let layer = view.container
        if visible {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.opacity = 0
            layer.transform = reduceMotion ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -Self.travel, 0)
            CATransaction.commit()
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(visible ? Self.fadeIn : Self.fadeOut)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: visible ? .easeOut : .easeIn))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        layer.opacity = visible ? 1 : 0
        if !reduceMotion {
            layer.transform = visible ? CATransform3DIdentity : CATransform3DMakeTranslation(0, Self.travel / 2, 0)
        }
        CATransaction.commit()
    }

    private func startLink() {
        guard link == nil else { return }
        let link = view.displayLink(target: LinkTarget(owner: self), selector: #selector(LinkTarget.tick(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    private func stopLink() {
        link?.invalidate()
        link = nil
    }

    fileprivate func tick(_ link: CADisplayLink) {
        let now = link.targetTimestamp
        switch state {
        case .recording, .handsFree:
            let dt = lastTimestamp.map { min(0.1, max(0.001, now - $0)) } ?? 1.0 / 60
            lastTimestamp = now
            showMeter(bars.step(level: levelSource(), dt: dt))
            updateChrome(now: now)
        case .processing:
            view.showRun(columns: BarModel.processingColumns(time: now - processingStart, columns: BarModel.barCount))
        case .message:
            let distance = view.messageScrollDistance
            let elapsed = now - messageStart
            if distance > 0 { view.setMessageOffset(Marquee.offset(distance: distance, at: elapsed)) }
            updateChrome(now: now)
            if recordingStart == nil, distance == 0 || elapsed > Marquee.duration(distance: distance) { stopLink() }
        case .hidden:
            stopLink()
        }
    }
}

/// `CADisplayLink` retains its target, so this holds the controller weakly; the link itself is dropped on hide.
private final class LinkTarget: NSObject {
    weak var owner: PillController?

    init(owner: PillController) {
        self.owner = owner
    }

    @MainActor @objc func tick(_ link: CADisplayLink) {
        owner?.tick(link)
    }
}
