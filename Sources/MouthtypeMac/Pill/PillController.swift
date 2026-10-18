// Panel set-up adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import QuartzCore

/// A borderless panel that never takes focus, so showing it cannot pull the app forward or move the caret.
final class PillPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// The floating pill, in whichever skin is selected: a level meter while recording (with the cancel and stop
/// controls once hands-free locks), a travelling wave while processing, and one line of text for a message. The
/// panel is built once at init and only ordered in and out; the display link runs only while something on screen
/// moves, so nothing runs while idle. The panel is click-through except while locked and the pointer is over a
/// control.
@MainActor
public final class PillController {
    enum State: Equatable {
        case hidden, recording, handsFree, processing, message(PillMessage)
    }

    static let horizontalPadding = PillGeometry.horizontalMargin
    static let pillPadding = PillGeometry.verticalMargin
    /// The standard-size panel; a large pill sits in a larger one, see `panelSize`.
    static let panelSize = PillGeometry.panelSize

    private(set) var state: State = .hidden
    let panel: PillPanel
    let previewView: PillPreviewView
    let host: PillHostView
    private(set) var skinKind: PillSkinKind
    private(set) var skin: any PillSkinView
    /// What the size setting resolved to for the pill on screen or about to be.
    private(set) var pillScale: PillScale
    var panelSize: CGSize { PillGeometry.panelSize(for: pillScale) }

    /// Read once per frame while recording. `PillDemo` swaps it for a synthetic curve.
    var levelSource: @MainActor () -> LevelReading
    /// The loudest smoothed column, 0...1, once per frame while recording. The menu bar glyph follows it.
    var onLevel: (@MainActor (Float) -> Void)?
    /// A click on the cancel or stop control of a locked pill.
    var onControl: (@MainActor (PillControl) -> Void)?

    private let defaults: UserDefaults
    private var pillSize: PillSize
    private var readout: PillReadoutColour
    private var pendingSkin: PillSkinKind?
    private var bars = BarModel()
    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval?
    private var processingStart: CFTimeInterval = 0
    /// When the current recording began; nil outside a recording and its notices.
    private var recordingStart: CFTimeInterval?
    private var messageStart: CFTimeInterval = 0
    /// Bumped by every state change, so a message timer or a hide completion only acts on its own state.
    private var generation = 0
    private var pressedControl: PillControl?
    /// True while the message on screen is the one held under a card, which stays until the card goes.
    private(set) var cardHeld = false
    /// The delivery card folded into the pill (Matrix and Minimal), nil while the pill is a plain pill.
    private(set) var cardView: DeliveryCardView?
    private var cardReadout: CardReadout?
    /// Bumped by every grow and shrink, so a late fade or panel restore only acts on its own.
    private var growEpoch = 0
    /// How long the panel keeps its grown size after the card leaves, so the pill can animate back inside it.
    var cardSettle: TimeInterval = 0.4
    var isGrown: Bool { cardView != nil }

    public init(level: @escaping @MainActor () -> LevelReading, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        levelSource = level
        skinKind = PillSkinPreference.current(defaults)
        pillSize = PillSizePreference.current(defaults)
        readout = PillReadoutPreference.current(defaults)
        let scale = pillSize.resolved(visibleWidth: Self.pointerScreen()?.visibleFrame.width ?? 0)
        pillScale = scale
        skin = Self.makeSkin(skinKind, scale: scale, readout: readout)
        let panelSize = PillGeometry.panelSize(for: scale)
        host = PillHostView(frame: NSRect(origin: .zero, size: panelSize))
        previewView = PillPreviewView(frame: Self.previewFrame(panelSize: panelSize, scale: scale))
        panel = PillPanel(
            contentRect: NSRect(origin: .zero, size: panelSize),
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
        panel.contentView = host
        host.wantsLayer = true
        host.controlAt = { [weak self] point in self.flatMap { PillHit.control(at: point, frames: $0.skin.controlFrames) } }
        host.onPress = { [weak self] control in self?.press(control) }
        host.onActivate = { [weak self] control in self?.onControl?(control) }
        install(skin)
        GlassBackdropCache.shared.startObserving()
        host.addSubview(previewView)
        _ = NotificationCenter.default.addObserver(
            forName: Typography.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.skin.applyTypography(Typography.current())
                self?.previewView.applyTypography(Typography.current())
            }
        }
    }


    /// The live preview readout sits centred over the pill, one pill height higher at the large size.
    private static func previewFrame(panelSize: CGSize, scale: PillScale) -> NSRect {
        let width = ClassicPillLayout.messageCap
        return NSRect(
            x: ((panelSize.width - width) / 2).rounded(.down), y: 94 + ClassicPillLayout.height * (scale.factor - 1),
            width: width, height: 100
        )
    }

    private static func pointerScreen() -> PillPlacement.Screen? {
        let screens = NSScreen.screens.map { PillPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        return PillPlacement.screen(pointer: NSEvent.mouseLocation, screens: screens)
    }

    /// A skin whose assets can't load (a Hi-Fi bundle missing its art) falls back to Classic rather than crashing the
    /// app on a hotkey press.
    static func makeSkin(
        _ kind: PillSkinKind, scale: PillScale, readout: PillReadoutColour = .default,
        factory: (PillSkinKind, NSRect, PillScale, PillReadoutColour) throws -> any PillSkinView = {
            try PillSkinFactory.make($0, frame: $1, scale: $2, readout: $3)
        }
    ) -> any PillSkinView {
        let frame = NSRect(origin: .zero, size: PillGeometry.panelSize(for: scale))
        do {
            return try factory(kind, frame, scale, readout)
        } catch {
            Log.app.error("pill skin \(kind.rawValue, privacy: .public) unavailable, using Classic: \(String(describing: error), privacy: .public)")
            return ClassicPillView(frame: frame, size: scale)
        }
    }

    /// Slows every animation on the pill by `factor`, so a transition can be caught mid-way. Demo only.
    func slowAnimations(by factor: Float) {
        host.layer?.speed = 1 / max(1, factor)
    }

    private func install(_ new: any PillSkinView) {
        skin.removeFromSuperview()
        skin = new
        new.frame = host.bounds
        new.autoresizingMask = [.width, .height]
        new.applyTypography(Typography.current())
        host.addSubview(new, positioned: .below, relativeTo: previewView.superview == host ? previewView : nil)
        host.skinReplaced()
    }

    /// Switches skins at once when the pill is down, else at the next time it shows, so a recording is never
    /// redrawn under the user. A changed size setting is picked up the same way.
    func setSkin(_ kind: PillSkinKind) {
        pendingSkin = kind
        if !isShown { applyPendingSkin() }
    }

    /// Settles the skin and size for the screen the pill is about to appear on, rebuilding only when something
    /// differs from what is installed. Runs while the pill is hidden, never under a recording.
    private func applyPendingSkin() {
        let kind = pendingSkin ?? skinKind
        pendingSkin = nil
        pillSize = PillSizePreference.current(defaults)
        let scale = pillSize.resolved(visibleWidth: Self.pointerScreen()?.visibleFrame.width ?? 0)
        let colour = PillReadoutPreference.current(defaults)
        guard kind != skinKind || scale != pillScale || (kind == .hifi && colour != readout) else { return }
        readout = colour
        skinKind = kind
        pillScale = scale
        panel.setContentSize(panelSize)
        previewView.frame = Self.previewFrame(panelSize: panelSize, scale: scale)
        install(Self.makeSkin(kind, scale: scale, readout: colour))
    }

    public func showRecording() {
        enter(.recording)
        recordingStart = CACurrentMediaTime()
        skin.showRecording(locked: false)
        beginMeter()
    }

    /// The same meter with the lock look and, once clicked, the cancel and stop controls.
    public func showHandsFree() {
        enter(.handsFree)
        if recordingStart == nil { recordingStart = CACurrentMediaTime() }
        skin.showRecording(locked: true)
        beginMeter()
    }

    /// One line over a hands-free recording, then back to the hands-free pill unless something else took over.
    public func showHandsFreeNotice(_ text: String, duration: TimeInterval = 4) {
        guard state == .handsFree else { return }
        let message = PillMessage(text)
        enter(.message(message))
        presentMessage(message, overRecording: true, duration: duration) { [weak self] in self?.showHandsFree() }
    }

    func showPreview(_ text: String) {
        guard state == .recording || state == .handsFree else { return }
        previewView.update(text)
    }

    public func showProcessing() {
        enter(.processing)
        recordingStart = nil
        skin.beginProcessing()
        processingStart = CACurrentMediaTime()
        startLink()
    }

    func showMessage(_ message: PillMessage, duration: TimeInterval = 2.5) {
        enter(.message(message))
        recordingStart = nil
        presentMessage(message, overRecording: false, duration: duration) { [weak self] in self?.hide() }
    }

    /// The line under a delivery card: the message stays up, click-through, until `hideCardMessage` or another state
    /// takes over.
    func showCardMessage(_ message: PillMessage) {
        enter(.message(message))
        cardHeld = true
        recordingStart = nil
        // A folded card's readout row already says the short thing, so the long line has nowhere to go.
        if let cardReadout, isGrown {
            skin.showCardReadout(cardReadout)
            placeCardView()
            startLink()
        } else {
            presentMessage(message, overRecording: false, duration: nil) {}
        }
    }

    /// Takes the pill down if it is still showing the card's line, and leaves anything newer alone.
    func hideCardMessage() {
        if cardHeld { hide() }
    }

    func showMessage(_ text: String, isError: Bool = false, duration: TimeInterval = 2.5) {
        showMessage(PillMessage(text, isError: isError), duration: duration)
    }

    public func hide() {
        previewView.update("")
        if isGrown, let cardReadout {
            // The card outlives whatever the pill was doing: the pill goes back to being its readout row.
            generation += 1
            cardHeld = false
            state = .hidden
            recordingStart = nil
            skin.showCardReadout(cardReadout)
            placeCardView()
            startLink()
            refreshInteractivity()
            return
        }
        guard state != .hidden else { return }
        generation += 1
        cardHeld = false
        state = .hidden
        recordingStart = nil
        stopLink()
        endInteraction()
        let shown = generation
        skin.disappear(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) { [weak self] in
            guard let self, self.generation == shown else { return }
            self.panel.orderOut(nil)
        }
    }

    private var isShown: Bool { state != .hidden || isGrown }

    private func beginMeter() {
        bars.reset()
        lastTimestamp = nil
        skin.showFractions(bars.step(reading: .silence, dt: 0))
        onLevel?(0)
        updateChrome(now: CACurrentMediaTime())
        startLink()
    }

    /// Timer and REC lamp, from the recording's own clock.
    private func updateChrome(now: CFTimeInterval) {
        guard let start = recordingStart else { return }
        skin.setElapsed(max(0, now - start))
    }

    /// Shows `message`, and runs `after` once it has been up for `duration`, or for as long as it takes to scroll through.
    private func presentMessage(
        _ message: PillMessage, overRecording: Bool, duration: TimeInterval?,
        then after: @escaping @MainActor () -> Void
    ) {
        skin.showMessage(message, overRecording: overRecording)
        placeCardView()
        messageStart = CACurrentMediaTime()
        let distance = skin.messageScrollDistance
        if distance > 0 || recordingStart != nil || isGrown { startLink() } else { stopLink() }
        guard let duration else { return }
        let shownFor = distance > 0 ? max(duration, Marquee.duration(distance: distance) + 0.3) : duration
        let shown = generation
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(shownFor))
            guard let self, self.generation == shown else { return }
            after()
        }
    }

    /// Moves to `next`, placing and showing the panel unless it is already up.
    private func enter(_ next: State) {
        generation += 1
        cardHeld = false
        let wasShown = isShown
        state = next
        if next != .recording && next != .handsFree { previewView.update("") }
        if next != .handsFree { endInteraction() }
        guard !wasShown else { return }
        applyPendingSkin()
        place()
        panel.orderFrontRegardless()
        skin.appear(reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
    }

    private func place() {
        let screens = NSScreen.screens.map { PillPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let origin = PillPlacement.origin(
            pointer: NSEvent.mouseLocation, screens: screens, panelSize: panelSize, pillPadding: Self.pillPadding
        ) else { return }
        panel.setFrame(
            NSRect(origin: CGPoint(x: origin.x.rounded(.down), y: origin.y.rounded(.down)), size: panelSize), display: false
        )
    }

    /// Where the pill sits, or would if it showed now, for the card that goes above it.
    func cardAnchor() -> DeliveryCardController.Anchor? {
        let pointer = NSEvent.mouseLocation
        let placements = NSScreen.screens.map { PillPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let screen = PillPlacement.screen(pointer: pointer, screens: placements) else { return nil }
        // A hidden pill shows at the size this screen resolves to, which is what the card has to clear.
        let scale = state == .hidden
            ? PillSizePreference.current(defaults).resolved(visibleWidth: screen.visibleFrame.width) : pillScale
        let size = PillGeometry.panelSize(for: scale)
        guard let origin = PillPlacement.origin(
            pointer: pointer, screens: placements, panelSize: size, pillPadding: Self.pillPadding
        ) else { return nil }
        return .init(
            midX: origin.x.rounded(.down) + size.width / 2,
            top: origin.y.rounded(.down) + Self.pillPadding + skinKind.pillHeight * scale.factor,
            visible: screen.visibleFrame, style: skinKind.cardStyle, scale: scale, merger: self
        )
    }

    // MARK: Card

    /// Whether the panel holds the card's readout alone: nothing the pill is doing sits in the row.
    private var rowIsCards: Bool { state == .hidden || cardHeld }

    /// Room under the pill for a message wrapped onto a few lines while a card is up.
    private static let cardRowRoom: CGFloat = 3 * MatrixPillLayout.height

    /// The panel's size with a card of `face` folded in: the usual panel, or taller and wider to hold the card, with its
    /// bottom edge and middle where they were.
    private func growPanel(forFace face: CGSize) {
        let k = pillScale.factor
        let margin = CardLayout.shadowMargin * k
        let size = CGSize(
            width: max(panelSize.width, face.width + 2 * margin),
            height: max(panelSize.height, Self.pillPadding + face.height + Self.cardRowRoom * k + margin)
        )
        let old = panel.frame
        let origin = CGPoint(x: (old.midX - size.width / 2).rounded(.down), y: old.minY)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
    }

    private func restorePanelSize() {
        let old = panel.frame
        let origin = CGPoint(x: (old.midX - panelSize.width / 2).rounded(.down), y: old.minY)
        panel.setFrame(NSRect(origin: origin, size: panelSize), display: false)
    }

    private func placeCardView() {
        guard let cardView, let frame = skin.cardFrame else { return }
        cardView.setFrameOrigin(frame.origin)
    }

    /// Grows the pill into `view`'s card, `face` big. The pill panel grows to hold it and the pill's row keeps saying
    /// `readout`. False when this skin has no card form, and the card needs a panel of its own.
    @discardableResult
    func growCard(view: DeliveryCardView, face: CGSize, readout: CardReadout) -> Bool {
        if !isShown { applyPendingSkin() }
        guard skin.growsIntoCard else { return false }
        growEpoch += 1
        let wasShown = isShown
        cardReadout = readout
        if cardView !== view {
            cardView?.removeFromSuperview()
            cardView = view
            view.removeFromSuperview()
            host.addSubview(view)
            host.cardView = view
        }
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if !wasShown {
            generation += 1
            place()
            growPanel(forFace: face)
            panel.orderFrontRegardless()
            skin.appear(reduceMotion: reduce)
        } else {
            growPanel(forFace: face)
        }
        skin.growCard(width: face.width, height: face.height, readout: readout, showReadout: rowIsCards)
        view.setFrameSize(face)
        placeCardView()
        if view.alphaValue < 1 || !wasShown {
            view.alphaValue = 0
            NSAnimationContext.runAnimationGroup { context in
                context.duration = reduce ? 0.15 : 0.12
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                view.animator().alphaValue = 1
            }
        }
        startLink()
        refreshInteractivity()
        return true
    }

    /// The card's countdown ticked: the row's clock and bar follow.
    func updateCardReadout(_ readout: CardReadout) {
        guard isGrown else { return }
        cardReadout = readout
        skin.updateCardReadout(readout)
    }

    /// The card is gone: the capsule shrinks back to a pill inside the grown panel, which goes back to its size once
    /// the motion is done. A pill that only existed for the card goes with it.
    func shrinkCard() {
        guard let view = cardView else { return }
        growEpoch += 1
        let epoch = growEpoch
        cardView = nil
        cardReadout = nil
        host.cardView = nil
        let reduce = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = reduce ? 0.12 : 0.08
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.growEpoch == epoch, view.superview === self.host else { return }
                view.removeFromSuperview()
            }
        })
        skin.shrinkCard()
        endInteraction()
        if state == .hidden {
            generation += 1
            stopLink()
            let shown = generation
            skin.disappear(reduceMotion: reduce) { [weak self] in
                guard let self, self.generation == shown else { return }
                self.panel.orderOut(nil)
                self.restorePanelSize()
            }
            return
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(self?.cardSettle ?? 0))
            guard let self, self.growEpoch == epoch, !self.isGrown else { return }
            self.restorePanelSize()
        }
    }

    // MARK: Clicks

    /// Keeps the panel click-through except while a locked pill has the pointer over a control (or a press is in
    /// flight), so the rest of the panel never swallows a click meant for the window underneath. While a card is
    /// folded in, the card's own frame takes clicks too, and only that frame. `pointer` is in screen coordinates.
    func updateInteractivity(pointer: CGPoint) {
        let local = host.convert(panel.convertPoint(fromScreen: pointer), from: nil)
        if let card = skin.grownFrame, isGrown {
            let control = state == .handsFree ? PillHit.control(at: local, frames: skin.controlFrames) : nil
            // A press that started on the card keeps the panel live until the button comes up.
            let dragging = !panel.ignoresMouseEvents && NSEvent.pressedMouseButtons & 1 != 0
            panel.ignoresMouseEvents = !card.contains(local) && pressedControl == nil && !dragging
            skin.setHovered(pressedControl == nil ? control : nil)
            return
        }
        guard state == .handsFree else {
            endInteraction()
            return
        }
        let frames = skin.controlFrames
        let control = PillHit.control(at: local, frames: frames)
        panel.ignoresMouseEvents = control == nil && pressedControl == nil
        skin.setHovered(pressedControl == nil ? control : nil)
    }

    private func refreshInteractivity() {
        if isGrown { updateInteractivity(pointer: NSEvent.mouseLocation) } else { endInteraction() }
    }

    private func press(_ control: PillControl?) {
        pressedControl = control
        skin.setPressed(control)
        if control != nil { skin.setHovered(nil) }
    }

    private func endInteraction() {
        pressedControl = nil
        skin.setPressed(nil)
        skin.setHovered(nil)
        if isGrown {
            updateInteractivity(pointer: NSEvent.mouseLocation)
        } else {
            panel.ignoresMouseEvents = true
        }
    }

    private func startLink() {
        guard link == nil else { return }
        let link = host.displayLink(target: LinkTarget(owner: self), selector: #selector(LinkTarget.tick(_:)))
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
            let fractions = bars.step(reading: levelSource(), dt: dt)
            skin.showFractions(fractions)
            onLevel?(fractions.max() ?? 0)
            updateChrome(now: now)
            if state == .handsFree || isGrown { updateInteractivity(pointer: NSEvent.mouseLocation) }
        case .processing:
            skin.updateProcessing(time: now - processingStart)
            if isGrown { updateInteractivity(pointer: NSEvent.mouseLocation) }
        case .message:
            let distance = skin.messageScrollDistance
            let elapsed = now - messageStart
            if distance > 0 { skin.setMessageOffset(Marquee.offset(distance: distance, at: elapsed)) }
            updateChrome(now: now)
            if isGrown { updateInteractivity(pointer: NSEvent.mouseLocation) }
            if recordingStart == nil, !isGrown, distance == 0 || elapsed > Marquee.duration(distance: distance) { stopLink() }
        case .hidden:
            if isGrown { updateInteractivity(pointer: NSEvent.mouseLocation) } else { stopLink() }
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
