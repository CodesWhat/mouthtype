import AppKit
import QuartzCore

/// A borderless panel that never takes focus: it can't become key or main, so clicking a card button neither
/// activates Mouthtype nor moves the caret in the app being dictated into.
final class CardPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// What a pill that folds the delivery card into itself (Matrix, Minimal) offers the card surface.
@MainActor
protocol CardMerging: AnyObject {
    /// Grows the pill into `view`, a card `face` big. False when the pill in use has no card form.
    @discardableResult
    func growCard(view: DeliveryCardView, face: CGSize, readout: CardReadout) -> Bool
    func updateCardReadout(_ readout: CardReadout)
    /// The card is gone; the pill shrinks back.
    func shrinkCard()
}

extension PillController: CardMerging {}

/// The card's window: builds the panel once, places it just above where the pill sits, and fades it in and out. For
/// the skins that fold the card into the pill there is no window of its own: the card's content goes to the pill.
@MainActor
final class DeliveryCardController: CardSurface {
    /// Where the pill sits (or will): its middle, its top edge, the visible area of its screen, and the skin and size
    /// whose card is drawn. A pill that can hold the card itself hands over `merger`.
    struct Anchor {
        var midX: CGFloat
        var top: CGFloat
        var visible: CGRect
        var style: CardStyle = .classic
        var scale: PillScale = .standard
        /// The tallest a card folded into the pill may be and still fit above it on the screen; nil is no limit.
        var maxFaceHeight: CGFloat?
        /// The Hi-Fi readout colour, which the Hi-Fi card's text and bar wear.
        var readout: PillReadoutColour = .default
        weak var merger: (any CardMerging)?
    }

    let panel: CardPanel
    let view: DeliveryCardView
    /// The same card drawn for a pill that folds it in.
    let mergedView: DeliveryCardView
    var anchor: @MainActor () -> Anchor? = { nil }
    /// Where the readout colour setting is read when it changes under an open card.
    var defaults = UserDefaults.standard
    /// The colour the setting changed to while this card was up; the pill's anchor only learns it when it next shows.
    private var readoutOverride: PillReadoutColour?
    var onAction: (@MainActor (CardAction) -> Void)? {
        didSet {
            view.onAction = onAction
            mergedView.onAction = onAction
        }
    }
    var onDismiss: (@MainActor () -> Void)? {
        didSet {
            view.onDismiss = onDismiss
            mergedView.onDismiss = onDismiss
        }
    }

    /// True while the card lives inside the pill rather than in this controller's panel.
    private(set) var isMerged = false
    private weak var merger: (any CardMerging)?
    private var shown = false
    private var generation = 0
    private var ticker: Task<Void, Never>?
    private var current: CardViewState?
    /// The card whose Undo clock is running and when it began, so both views show the same clock.
    private var countdown: (card: DeliveryCard, start: CFTimeInterval)?

    init() {
        view = DeliveryCardView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
        mergedView = DeliveryCardView(frame: .zero)
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
        _ = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshReadoutColour() }
        }
    }

    /// Redraws an open Hi-Fi card when the readout colour setting has changed since it was drawn.
    func refreshReadoutColour() {
        guard shown, !isMerged, let state = current, view.style == .hifi else { return }
        let colour = PillReadoutPreference.current(defaults)
        guard colour != view.hifiReadout else { return }
        readoutOverride = colour
        render(state)
    }

    func render(_ state: CardViewState?) {
        guard let state else {
            hide()
            return
        }
        let first = anchor()
        let firstStyle = first?.style ?? .classic
        let firstScale = first?.scale ?? .standard
        if firstStyle.mergesIntoPill, let merger = first?.merger,
           renderMerged(state, style: firstStyle, scale: firstScale, maxFaceHeight: first?.maxFaceHeight, merger: merger) {
            return
        }
        guard firstStyle.mergesIntoPill else {
            renderPanel(state, anchor: first, style: firstStyle, scale: firstScale)
            return
        }
        // The pill had no card form after all. Draw on the skin actually installed now, which has a body of its own,
        // or on Classic's.
        let now = anchor()
        let style = now.map { $0.style.mergesIntoPill ? CardStyle.classic : $0.style } ?? .classic
        renderPanel(state, anchor: now, style: style, scale: now?.scale ?? firstScale)
    }

    /// The start of `card`'s countdown: when it first rendered, whichever view drew it.
    private func countdownStart(for card: DeliveryCard) -> CFTimeInterval? {
        guard card.countdown != nil else {
            countdown = nil
            return nil
        }
        if let countdown, countdown.card == card { return countdown.start }
        let start = CACurrentMediaTime()
        countdown = (card, start)
        return start
    }

    /// The card goes into the pill. False when the pill has no card form after all.
    private func renderMerged(
        _ state: CardViewState, style: CardStyle, scale: PillScale, maxFaceHeight: CGFloat?, merger: any CardMerging
    ) -> Bool {
        mergedView.configure(style: style, scale: scale, embedded: true)
        mergedView.maxFaceHeight = maxFaceHeight
        mergedView.render(state, typography: Typography.current(), countdownStart: countdownStart(for: state.card))
        guard let readout = mergedView.readout, merger.growCard(view: mergedView, face: mergedView.faceSize, readout: readout) else {
            return false
        }
        let isNew = current?.card != state.card || !shown || !isMerged
        current = state
        if !isMerged {
            // It was a card of its own a moment ago: that window goes at once, the pill takes over.
            generation += 1
            panel.orderOut(nil)
        }
        self.merger = merger
        isMerged = true
        shown = true
        if isNew {
            generation += 1
            startTicker(for: state.card)
        }
        return true
    }

    private func renderPanel(_ state: CardViewState, anchor: Anchor?, style: CardStyle, scale: PillScale) {
        if isMerged {
            // The skin changed to one with its own panel for the card: the pill gives the card back.
            merger?.shrinkCard()
            merger = nil
            isMerged = false
            shown = false
        }
        let isNew = current?.card != state.card || !shown
        current = state
        view.configure(style: style, scale: scale, embedded: false, readout: readoutOverride ?? anchor?.readout ?? .default)
        let size = view.render(state, typography: Typography.current(), countdownStart: countdownStart(for: state.card))
        if let anchor {
            panel.setFrame(
                CardLayout.panelFrame(
                    face: view.faceSize, pillMidX: anchor.midX, pillTop: anchor.top, visible: anchor.visible, scale: scale.factor
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
            view.refreshBackdrop()
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
        countdown = nil
        readoutOverride = nil
        ticker?.cancel()
        ticker = nil
        if isMerged {
            isMerged = false
            merger?.shrinkCard()
            merger = nil
            return
        }
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
                guard let self else { return }
                if self.isMerged {
                    self.mergedView.tick()
                    if let readout = self.mergedView.readout { self.merger?.updateCardReadout(readout) }
                } else {
                    self.view.tick()
                }
            }
        }
    }

    /// Screen position of a control's middle (AppKit screen coordinates, origin bottom left), for the click test.
    func screenCenter(of action: CardAction) -> CGPoint? {
        let card = isMerged ? mergedView : view
        guard let local = card.center(of: action), let window = card.window else { return nil }
        return window.convertPoint(toScreen: card.convert(local, to: nil))
    }

    var dismissScreenCenter: CGPoint {
        let card = isMerged ? mergedView : view
        return card.window?.convertPoint(toScreen: card.convert(card.dismissCenter, to: nil)) ?? .zero
    }
}
