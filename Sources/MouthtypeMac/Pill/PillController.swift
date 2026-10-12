// Panel set-up adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import QuartzCore

/// A borderless panel that never takes focus, so showing it cannot pull the app forward or move the caret.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating pill: live level bars while recording, a calm ripple while processing, one line of text for a
/// message. The panel is built once at init and only ordered in and out; the display link runs only while bars are
/// on screen, so nothing runs while idle.
@MainActor
public final class PillController {
    enum State: Equatable {
        case hidden, recording, processing, message(String)
    }

    static let panelSize = CGSize(width: 360, height: 40)
    static let pillPadding: CGFloat = (panelSize.height - PillView.pillSize.height) / 2
    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.16
    private static let hiddenScale: CGFloat = 0.85

    private(set) var state: State = .hidden
    let panel: PillPanel
    let view: PillView

    /// Read once per frame while recording. `PillDemo` swaps it for a synthetic curve.
    var levelSource: @MainActor () -> Float

    private var bars = BarModel()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var rippleStart: CFTimeInterval = 0
    /// Bumped by every state change, so a message timer or a hide completion only acts on its own state.
    private var generation = 0

    public init(level: @escaping @MainActor () -> Float) {
        levelSource = level
        view = PillView(
            frame: NSRect(origin: .zero, size: Self.panelSize),
            maxPillWidth: Self.panelSize.width - 2 * PillView.messagePadding
        )
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
        bars.reset()
        lastTimestamp = nil
        view.showBars(bars.step(level: 0, dt: 0))
        startLink()
    }

    public func showProcessing() {
        enter(.processing)
        rippleStart = CACurrentMediaTime()
        view.showBars(BarModel.ripple(time: 0))
        startLink()
    }

    public func showMessage(_ text: String, duration: TimeInterval = 2.5) {
        let wasVisible = isShown
        enter(.message(text))
        stopLink()
        view.showMessage(text, animated: wasVisible)
        let shown = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard let self, self.generation == shown else { return }
            self.hide()
        }
    }

    public func hide() {
        guard state != .hidden else { return }
        generation += 1
        state = .hidden
        stopLink()
        let shown = generation
        animate(visible: false) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private var isShown: Bool { state != .hidden }

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
        panel.setFrameOrigin(origin)
    }

    private func animate(visible: Bool, completion: (@MainActor () -> Void)?) {
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let layer = view.container
        let scale = visible ? 1 : Self.hiddenScale
        CATransaction.begin()
        CATransaction.setAnimationDuration(visible ? Self.fadeIn : Self.fadeOut)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: visible ? .easeOut : .easeIn))
        CATransaction.setCompletionBlock {
            MainActor.assumeIsolated { completion?() }
        }
        layer.opacity = visible ? 1 : 0
        if !reduceMotion {
            layer.transform = CATransform3DMakeScale(scale, scale, 1)
        }
        CATransaction.commit()
        if reduceMotion, visible { layer.transform = CATransform3DIdentity }
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
        switch state {
        case .recording:
            let dt = lastTimestamp.map { min(0.1, max(0.001, link.targetTimestamp - $0)) } ?? 1.0 / 60
            lastTimestamp = link.targetTimestamp
            view.showBars(bars.step(level: levelSource(), dt: dt))
        case .processing:
            view.showBars(BarModel.ripple(time: link.targetTimestamp - rippleStart))
        case .hidden, .message:
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
