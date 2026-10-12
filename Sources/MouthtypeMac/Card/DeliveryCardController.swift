import AppKit
import QuartzCore

/// A borderless panel that never takes focus: it can't become key or main, so clicking a card button neither
/// activates Mouthtype nor moves the caret in the app being dictated into.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The card's window: builds the panel once, places it just above where the pill sits, and fades it in and out.
@MainActor
final class DeliveryCardController: CardSurface {
    /// Where the pill sits (or will): its middle, its top edge, and the visible area of its screen.
    struct Anchor {
        var midX: CGFloat
        var top: CGFloat
        var visible: CGRect
    }

    let panel: CardPanel
    let view: DeliveryCardView
    var anchor: @MainActor () -> Anchor? = { nil }
    var onAction: (@MainActor (CardAction) -> Void)? { didSet { view.onAction = onAction } }
    var onDismiss: (@MainActor () -> Void)? { didSet { view.onDismiss = onDismiss } }

    private var shown = false
    private var generation = 0
    private var ticker: Task<Void, Never>?
    private var current: CardViewState?

    init() {
        view = DeliveryCardView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        panel = CardPanel(
            contentRect: view.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.contentView = view
        // The observer holds self weakly and lives as long as the app does.
        _ = NotificationCenter.default.addObserver(
            forName: Typography.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let state = self.current else { return }
                self.render(state)
            }
        }
    }

    func render(_ state: CardViewState?) {
        guard let state else {
            hide()
            return
        }
        let isNew = current?.card != state.card || !shown
        current = state
        let size = view.render(state, typography: Typography.current())
        if let anchor = anchor() {
            panel.setFrame(
                CardLayout.panelFrame(
                    face: view.faceSize, pillMidX: anchor.midX, pillTop: anchor.top, visible: anchor.visible
                ), display: true
            )
        } else {
            panel.setContentSize(size)
        }
        guard isNew else { return }
        generation += 1
        if !shown {
            panel.orderFrontRegardless()
            shown = true
        }
        animateIn()
        startTicker(for: state.card)
    }

    private func hide() {
        guard shown else { return }
        generation += 1
        let mine = generation
        shown = false
        current = nil
        ticker?.cancel()
        ticker = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        CATransaction.begin()
        CATransaction.setAnimationDuration(reduce ? 0.12 : 0.14)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(controlPoints: 0.55, 0.055, 0.675, 0.19))
        CATransaction.setCompletionBlock { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.generation == mine else { return }
                self.panel.orderOut(nil)
            }
        }
        view.layer?.opacity = 0
        CATransaction.commit()
    }

    /// 200 ms: opacity over 180 ms, rising 10 pt with a slight overshoot. Opacity only under Reduce Motion.
    private func animateIn() {
        guard let layer = view.layer else { return }
        layer.removeAllAnimations()
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        layer.opacity = 1
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0
        fade.toValue = 1
        fade.duration = reduce ? 0.12 : 0.18
        fade.timingFunction = CAMediaTimingFunction(name: .easeOut)
        layer.add(fade, forKey: "fade")
        guard !reduce else { return }
        let rise = CABasicAnimation(keyPath: "transform.translation.y")
        rise.fromValue = -10
        rise.toValue = 0
        rise.duration = 0.2
        rise.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.9, 0.3, 1.15)
        layer.add(rise, forKey: "rise")
    }

    private func startTicker(for card: DeliveryCard) {
        ticker?.cancel()
        ticker = nil
        guard card.countdown != nil else { return }
        ticker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                self?.view.tick()
            }
        }
    }

    /// Screen position of a control's middle (AppKit screen coordinates, origin bottom left), for the click test.
    func screenCenter(of action: CardAction) -> CGPoint? {
        guard let local = view.center(of: action) else { return nil }
        return panel.convertPoint(toScreen: view.convert(local, to: nil))
    }

    var dismissScreenCenter: CGPoint {
        panel.convertPoint(toScreen: view.convert(view.dismissCenter, to: nil))
    }
}
