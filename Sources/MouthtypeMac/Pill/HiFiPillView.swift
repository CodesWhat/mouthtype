import AppKit
import QuartzCore

/// The pill, drawn from sprites: a static chassis with live layers over it (meter segments, timer, lamps, caps,
/// message text), all placed on whole points from the skin's layout. Sprites are magnified nearest-neighbour at an
/// integer art scale so every art pixel stays a crisp block. The view never takes events, the host view over it does.
@MainActor
final class HiFiPillView: NSView, PillSkinView {
    let artScale: CGFloat
    static let artSize = CGSize(width: 146, height: 32)
    var pillSize: CGSize { CGSize(width: Self.artSize.width * artScale, height: Self.artSize.height * artScale) }

    private enum Mode { case meter, message }

    static let fadeIn: TimeInterval = 0.12
    static let fadeOut: TimeInterval = 0.16
    private var travel: CGFloat { 6 * artScale }

    /// Holds the pill and is what the show and hide animations fade and move.
    let container = CALayer()
    private let assets: PillAssets
    private let layout: PillLayout
    private let pill = CALayer()
    private let cover = CALayer()
    private var segments: [[CALayer]] = []
    private let timer = CALayer()
    private let padlock = CALayer()
    private let glow = CALayer()
    private let led = CALayer()
    private let talk = CALayer()
    private let cancel = CALayer()
    private let stop = CALayer()
    private let messageClip = CALayer()
    private let messageText = CALayer()

    private var mode = Mode.meter
    private(set) var readout: PillReadoutColour
    private var messageString = ""
    private var messageIsError = false
    /// The colour the current message was drawn in.
    private(set) var messageColor: CGColor?
    private var litCache: [[Bool]] = []
    private var timerSeconds: Int?
    private var ledOn = false
    private var talkDown = false
    private var messageWidth = 0
    private var pressedControl: PillControl?
    private(set) var isLocked = false
    /// How far the current message has to scroll, 0 when it sits centred.
    private(set) var messageScrollDistance = 0

    init(frame: NSRect, assets: PillAssets, size: PillScale = .standard, readout: PillReadoutColour = .default) {
        self.readout = readout
        artScale = size.factor
        self.assets = assets
        layout = assets.layout
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        container.frame = bounds
        container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.opacity = 0
        layer?.addSublayer(container)

        pill.frame = CGRect(
            x: ((bounds.width - pillSize.width) / 2).rounded(.down), y: PillGeometry.verticalMargin,
            width: pillSize.width, height: pillSize.height
        )
        container.addSublayer(pill)
        add(pill, image: assets.chassis, rect: PillLayout.Rect(x: 0, y: 0, w: layout.size.w, h: layout.size.h))

        cover.backgroundColor = PillLayout.color(hex: layout.colors.windowBackground)
        cover.frame = layerFrame(of: layout.window)
        cover.isHidden = true
        pill.addSublayer(cover)

        segments = layout.meter.segments.map { column in
            column.enumerated().map { row, rect in
                let segment = CALayer()
                segment.frame = layerFrame(of: rect)
                segment.backgroundColor = readout.palette(base: layout.colors).tier(layout.meter.rowTiers[row])
                segment.isHidden = true
                pill.addSublayer(segment)
                return segment
            }
        }

        add(pill, sprite: "led_glow", into: glow)
        add(pill, sprite: "led_off", into: led)
        add(pill, sprite: "talk_up", into: talk)
        add(pill, sprite: "cancel", into: cancel)
        add(pill, sprite: "stop", into: stop)
        add(pill, sprite: "padlock", into: padlock)
        glow.isHidden = true
        padlock.isHidden = true
        configure(timer)
        timer.isHidden = true
        pill.addSublayer(timer)

        let slot = layout.text.message
        let height = assets.fonts[slot.font]?.metrics.cellHeight ?? 7
        messageClip.frame = layerFrame(of: PillLayout.Rect(x: slot.x, y: slot.y, w: slot.maxWidth, h: height))
        messageClip.masksToBounds = true
        messageClip.isHidden = true
        pill.addSublayer(messageClip)
        configure(messageText)
        messageClip.addSublayer(messageText)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// The cap sprites' frames in this view, while locked and showing the meter.
    var controlFrames: [PillControl: CGRect] {
        guard isLocked, mode == .meter else { return [:] }
        return [.cancel: capFrame("cancel"), .stop: capFrame("stop")].compactMapValues { $0 }
    }

    private func capFrame(_ name: String) -> CGRect? {
        guard let spec = layout.sprites[name] else { return nil }
        return layerFrame(of: spec.rect).offsetBy(dx: pill.frame.minX, dy: pill.frame.minY)
    }

    // MARK: Layout helpers

    /// A layout rect (top-left origin, art pixels) as a frame in the pill layer.
    private func layerFrame(of rect: PillLayout.Rect) -> CGRect {
        let s = artScale
        return CGRect(
            x: CGFloat(rect.x) * s, y: CGFloat(layout.size.h - rect.y - rect.h) * s,
            width: CGFloat(rect.w) * s, height: CGFloat(rect.h) * s
        )
    }

    private func configure(_ layer: CALayer) {
        layer.magnificationFilter = .nearest
        layer.minificationFilter = .nearest
        layer.allowsEdgeAntialiasing = false
    }

    private func add(_ parent: CALayer, image: CGImage, rect: PillLayout.Rect, into layer: CALayer? = nil) {
        let target = layer ?? parent
        configure(target)
        target.contents = image
        if layer != nil {
            target.frame = layerFrame(of: rect)
            parent.addSublayer(target)
        }
    }

    private func add(_ parent: CALayer, sprite name: String, into layer: CALayer) {
        guard let image = assets.sprites[name], let spec = layout.sprites[name] else { return }
        add(parent, image: image, rect: spec.rect, into: layer)
    }

    private func setSprite(_ layer: CALayer, _ name: String) {
        layer.contents = assets.sprites[name]
    }

    private func withoutActions(_ body: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        body()
        CATransaction.commit()
    }

    // MARK: Readout colour

    /// Retints the meter segments, the timer and the message text. The chassis, lamps and caps keep their art.
    func setReadout(_ new: PillReadoutColour) {
        guard new != readout else { return }
        readout = new
        let palette = new.palette(base: layout.colors)
        withoutActions {
            for column in segments {
                for (row, segment) in column.enumerated() { segment.backgroundColor = palette.tier(layout.meter.rowTiers[row]) }
            }
        }
        renderTimer()
        if mode == .message { showMessage(messageString, isError: messageIsError) }
    }

    /// The colour a meter row is drawn in, for tests.
    func segmentColor(column: Int, row: Int) -> CGColor? { segments[column][row].backgroundColor }
    /// The colour the timer and message text are tinted, for tests.
    var textColor: CGColor { PillLayout.color(hex: readout.palette(base: layout.colors).text) }

    // MARK: Meter

    /// Meter mode with `counts[column]` segments lit from the baseline up.
    func showMeter(litCounts counts: [Int]) {
        let lit = segments.enumerated().map { column, rows in
            let count = column < counts.count ? counts[column] : 0
            return rows.indices.map { $0 < count }
        }
        showSegments(lit)
    }

    /// Processing: one middle-row segment lit in each column of `columns`.
    func showRun(columns: ClosedRange<Int>) {
        let row = segments.first.map { $0.count / 2 } ?? 0
        let lit = segments.enumerated().map { column, rows in
            rows.indices.map { columns.contains(column) && $0 == row }
        }
        showSegments(lit)
    }

    private func showSegments(_ lit: [[Bool]]) {
        if mode != .meter { setMode(.meter) }
        guard lit != litCache else { return }
        litCache = lit
        withoutActions {
            for (column, rows) in segments.enumerated() {
                for (row, segment) in rows.enumerated() { segment.isHidden = !lit[column][row] }
            }
        }
    }

    private func setMode(_ new: Mode) {
        mode = new
        withoutActions {
            let meter = new == .meter
            cover.isHidden = meter
            messageClip.isHidden = meter
            if !meter {
                litCache = []
                segments.forEach { $0.forEach { $0.isHidden = true } }
            }
            padlock.isHidden = !(meter && isLocked)
            timer.isHidden = !(meter && timerSeconds != nil)
        }
    }

    // MARK: Chrome

    /// The timer readout beside the meter, nil to blank it.
    func setTimer(seconds: Int?) {
        guard seconds != timerSeconds else { return }
        timerSeconds = seconds
        renderTimer()
    }

    private func renderTimer() {
        withoutActions {
            guard let seconds = timerSeconds else { timer.isHidden = true; return }
            let slot = isLocked ? layout.text.timerLocked : layout.text.timer
            guard let font = assets.fonts[slot.font],
                  let image = font.image(
                      for: PillTimeline.timerText(seconds: seconds), color: PillLayout.color(hex: readout.palette(base: layout.colors).text)
                  ) else { return }
            timer.contents = image
            timer.frame = layerFrame(of: PillLayout.Rect(x: slot.x, y: slot.y, w: image.width, h: image.height))
            timer.isHidden = mode != .meter
        }
    }

    func setLED(_ on: Bool) {
        guard on != ledOn else { return }
        ledOn = on
        withoutActions {
            setSprite(led, on ? "led_on" : "led_off")
            glow.isHidden = !on
        }
    }

    /// The push button stays down while a hold recording runs.
    func setTalkDown(_ down: Bool) {
        guard down != talkDown else { return }
        talkDown = down
        withoutActions { setSprite(talk, down ? "talk_down" : "talk_up") }
    }

    /// Hands-free look: padlock beside the timer, cancel and stop caps lit.
    func setLocked(_ locked: Bool) {
        guard locked != isLocked else { return }
        isLocked = locked
        withoutActions { padlock.isHidden = !(locked && mode == .meter) }
        refreshCaps()
        renderTimer()
    }

    /// Lit caps while locked; a pressed cap drops to its unlit sprite and sits one art pixel lower.
    private func refreshCaps() {
        withoutActions {
            for (control, layer, name) in [(PillControl.cancel, cancel, "cancel"), (.stop, stop, "stop")] {
                let down = pressedControl == control
                setSprite(layer, isLocked && !down ? name + "_lit" : name)
                guard let spec = layout.sprites[name] else { continue }
                var frame = layerFrame(of: spec.rect)
                if down { frame.origin.y -= artScale }
                layer.frame = frame
            }
        }
    }

    func setHovered(_ control: PillControl?) {}

    func setPressed(_ control: PillControl?) {
        guard control != pressedControl else { return }
        pressedControl = control
        refreshCaps()
    }

    // MARK: Protocol entry points

    func showRecording(locked: Bool) {
        setLocked(locked)
        setTalkDown(!locked)
    }

    func beginProcessing() {
        setLocked(false)
        setTalkDown(false)
        setLED(false)
        setTimer(seconds: nil)
        showRun(columns: BarModel.processingColumns(time: 0, columns: BarModel.barCount))
    }

    func showMessage(_ message: PillMessage, overRecording: Bool) {
        if !overRecording {
            setLocked(false)
            setTalkDown(false)
            setLED(false)
            setTimer(seconds: nil)
        }
        showMessage(message.singleLine, isError: message.isError)
    }

    func applyTypography(_ typography: Typography) {}

    func showFractions(_ fractions: [Float]) {
        showMeter(litCounts: BarModel.litSegments(fractions, segments: BarModel.segmentRows))
    }

    func updateProcessing(time: TimeInterval) {
        showRun(columns: BarModel.processingColumns(time: time, columns: BarModel.barCount))
    }

    func setElapsed(_ seconds: TimeInterval?) {
        guard let seconds else { return }
        setTimer(seconds: Int(max(0, seconds)))
        setLED(PillTimeline.ledOn(elapsed: seconds, locked: isLocked))
    }

    /// A short fade with a few points of upward travel; fade only under Reduce Motion.
    func appear(reduceMotion: Bool) {
        withoutActions {
            container.opacity = 0
            container.transform = reduceMotion ? CATransform3DIdentity : CATransform3DMakeTranslation(0, -travel, 0)
        }
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeIn)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        container.opacity = 1
        container.transform = CATransform3DIdentity
        CATransaction.commit()
    }

    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void) {
        CATransaction.begin()
        CATransaction.setAnimationDuration(Self.fadeOut)
        CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeIn))
        CATransaction.setCompletionBlock { MainActor.assumeIsolated { completion() } }
        container.opacity = 0
        if !reduceMotion { container.transform = CATransform3DMakeTranslation(0, travel / 2, 0) }
        CATransaction.commit()
    }

    // MARK: Message

    /// Replaces the meter and timer with `text` in the 5x7 face, uppercased by the font's lookup. Centred when it
    /// fits the window, otherwise left for the controller to scroll with `setMessageOffset`.
    func showMessage(_ text: String, isError: Bool = false) {
        let slot = layout.text.message
        guard let font = assets.fonts[slot.font] else { return }
        messageString = text
        messageIsError = isError
        let palette = readout.palette(base: layout.colors)
        let color = PillLayout.color(hex: isError ? palette.error : palette.text)
        messageColor = color
        let image = font.image(for: text, color: color)
        messageWidth = image?.width ?? 0
        withoutActions {
            messageText.contents = image
            setMode(.message)
            padlock.isHidden = true
            timer.isHidden = true
            switch Marquee.layout(textWidth: messageWidth, windowWidth: slot.maxWidth) {
            case .centered(let offset):
                messageScrollDistance = 0
                placeMessage(at: offset)
            case .scrolling(let distance):
                messageScrollDistance = distance
                placeMessage(at: 0)
            }
        }
    }

    func setMessageOffset(_ offset: Int) {
        withoutActions { placeMessage(at: offset) }
    }

    private func placeMessage(at offset: Int) {
        messageText.frame = CGRect(
            x: CGFloat(offset) * artScale, y: 0,
            width: CGFloat(messageWidth) * artScale, height: messageClip.bounds.height
        )
    }
}
