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
    static let panelSize = PillGeometry.panelSize

    private(set) var state: State = .hidden
    let panel: PillPanel
    let host: PillHostView
    private(set) var skinKind: PillSkinKind
    private(set) var skin: any PillSkinView

    /// Read once per frame while recording. `PillDemo` swaps it for a synthetic curve.
    var levelSource: @MainActor () -> LevelReading
    /// A click on the cancel or stop control of a locked pill.
    var onControl: (@MainActor (PillControl) -> Void)?

    private let defaults: UserDefaults
    private var hiFiSize: HiFiPillSize
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

    public init(level: @escaping @MainActor () -> LevelReading, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        levelSource = level
        skinKind = PillSkinPreference.current(defaults)
        hiFiSize = HiFiPillSizePreference.current(defaults)
        skin = Self.makeSkin(skinKind, size: hiFiSize)
        host = PillHostView(frame: NSRect(origin: .zero, size: Self.panelSize))
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
        panel.contentView = host
        host.wantsLayer = true
        host.controlAt = { [weak self] point in self.flatMap { PillHit.control(at: point, frames: $0.skin.controlFrames) } }
        host.onPress = { [weak self] control in self?.press(control) }
        host.onActivate = { [weak self] control in self?.onControl?(control) }
        install(skin)
        _ = NotificationCenter.default.addObserver(
            forName: Typography.didChange, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.skin.applyTypography(Typography.current()) }
        }
    }


    private static func makeSkin(_ kind: PillSkinKind, size: HiFiPillSize) -> any PillSkinView {
        let frame = NSRect(origin: .zero, size: PillGeometry.panelSize)
        switch kind {
        case .classic:
            return ClassicPillView(frame: frame)
        case .hifi:
            do {
                return HiFiPillView(frame: frame, assets: try PillAssets.loadHiFi(), size: size)
            } catch {
                fatalError("pill resources missing from the bundle: \(error)")
            }
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
        host.addSubview(new)
        host.skinReplaced()
    }

    /// Switches skins at once when the pill is down, else at the next time it shows, so a recording is never
    /// redrawn under the user.
    func setSkin(_ kind: PillSkinKind) {
        let sizeChanged = kind == .hifi && HiFiPillSizePreference.current(defaults) != hiFiSize
        pendingSkin = kind == skinKind && !sizeChanged ? nil : kind
        if state == .hidden { applyPendingSkin() }
    }

    private func applyPendingSkin() {
        guard let kind = pendingSkin else { return }
        pendingSkin = nil
        skinKind = kind
        hiFiSize = HiFiPillSizePreference.current(defaults)
        install(Self.makeSkin(kind, size: hiFiSize))
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

    func showMessage(_ text: String, isError: Bool = false, duration: TimeInterval = 2.5) {
        showMessage(PillMessage(text, isError: isError), duration: duration)
    }

    public func hide() {
        guard state != .hidden else { return }
        generation += 1
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

    private var isShown: Bool { state != .hidden }

    private func beginMeter() {
        bars.reset()
        lastTimestamp = nil
        skin.showFractions(bars.step(reading: .silence, dt: 0))
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
        _ message: PillMessage, overRecording: Bool, duration: TimeInterval,
        then after: @escaping @MainActor () -> Void
    ) {
        skin.showMessage(message, overRecording: overRecording)
        messageStart = CACurrentMediaTime()
        let distance = skin.messageScrollDistance
        let shownFor = distance > 0 ? max(duration, Marquee.duration(distance: distance) + 0.3) : duration
        if distance > 0 || recordingStart != nil { startLink() } else { stopLink() }
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
        let wasShown = isShown
        state = next
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
            pointer: NSEvent.mouseLocation, screens: screens, panelSize: Self.panelSize, pillPadding: Self.pillPadding
        ) else { return }
        panel.setFrameOrigin(CGPoint(x: origin.x.rounded(.down), y: origin.y.rounded(.down)))
    }

    /// Where the pill sits, or would if it showed now, for the card that goes above it.
    func cardAnchor() -> DeliveryCardController.Anchor? {
        let pointer = NSEvent.mouseLocation
        let screens = NSScreen.screens
        let placements = screens.map { PillPlacement.Screen(frame: $0.frame, visibleFrame: $0.visibleFrame) }
        guard let origin = PillPlacement.origin(
            pointer: pointer, screens: placements, panelSize: Self.panelSize, pillPadding: Self.pillPadding
        ) else { return nil }
        let screen = screens.first { $0.frame.contains(pointer) } ?? screens.first
        return .init(
            midX: origin.x.rounded(.down) + Self.panelSize.width / 2,
            top: origin.y.rounded(.down) + Self.pillPadding
                + (skinKind == .hifi ? HiFiPillView.artSize.height * hiFiSize.scale : ClassicPillLayout.height),
            visible: screen?.visibleFrame ?? .zero
        )
    }

    // MARK: Clicks

    /// Keeps the panel click-through except while a locked pill has the pointer over a control (or a press is in
    /// flight), so the rest of the panel never swallows a click meant for the window underneath. `pointer` is in
    /// screen coordinates.
    func updateInteractivity(pointer: CGPoint) {
        guard state == .handsFree else {
            endInteraction()
            return
        }
        let local = host.convert(panel.convertPoint(fromScreen: pointer), from: nil)
        let frames = skin.controlFrames
        let control = PillHit.control(at: local, frames: frames)
        panel.ignoresMouseEvents = control == nil && pressedControl == nil
        skin.setHovered(pressedControl == nil ? control : nil)
    }

    private func press(_ control: PillControl?) {
        pressedControl = control
        skin.setPressed(control)
        if control != nil { skin.setHovered(nil) }
    }

    private func endInteraction() {
        pressedControl = nil
        panel.ignoresMouseEvents = true
        skin.setPressed(nil)
        skin.setHovered(nil)
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
            skin.showFractions(bars.step(reading: levelSource(), dt: dt))
            updateChrome(now: now)
            if state == .handsFree { updateInteractivity(pointer: NSEvent.mouseLocation) }
        case .processing:
            skin.updateProcessing(time: now - processingStart)
        case .message:
            let distance = skin.messageScrollDistance
            let elapsed = now - messageStart
            if distance > 0 { skin.setMessageOffset(Marquee.offset(distance: distance, at: elapsed)) }
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
