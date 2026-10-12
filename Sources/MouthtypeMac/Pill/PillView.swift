import AppKit
import QuartzCore

/// The pill, drawn from sprites: a static chassis with live layers over it (meter segments, timer, lamps, caps,
/// message text), all placed on whole points from the skin's layout. Sprites are magnified nearest-neighbour at an
/// integer art scale so every art pixel stays a crisp block. The view never takes events, and the panel around it
/// is click-through anyway.
@MainActor
final class PillView: NSView {
    /// Points per art pixel. 1 or 2; a setting later.
    static let artScale: CGFloat = 1
    static let artSize = CGSize(width: 146, height: 32)
    static let pillSize = CGSize(width: artSize.width * artScale, height: artSize.height * artScale)

    private enum Mode { case meter, message }

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
    private var litCache: [[Bool]] = []
    private var timerSeconds: Int?
    private var ledOn = false
    private var talkDown = false
    private var messageWidth = 0
    private(set) var isLocked = false
    /// How far the current message has to scroll, 0 when it sits centred.
    private(set) var messageScrollDistance = 0

    init(frame: NSRect, assets: PillAssets) {
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
            x: ((bounds.width - Self.pillSize.width) / 2).rounded(.down),
            y: ((bounds.height - Self.pillSize.height) / 2).rounded(.down),
            width: Self.pillSize.width, height: Self.pillSize.height
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
                segment.backgroundColor = layout.tierColor(layout.meter.rowTiers[row])
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

    // MARK: Layout helpers

    /// A layout rect (top-left origin, art pixels) as a frame in the pill layer.
    private func layerFrame(of rect: PillLayout.Rect) -> CGRect {
        let s = Self.artScale
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
                      for: PillTimeline.timerText(seconds: seconds), color: PillLayout.color(hex: layout.colors.text)
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
        withoutActions {
            setSprite(cancel, locked ? "cancel_lit" : "cancel")
            setSprite(stop, locked ? "stop_lit" : "stop")
            padlock.isHidden = !(locked && mode == .meter)
        }
        renderTimer()
    }

    // MARK: Message

    /// Replaces the meter and timer with `text` in the 5x7 face, uppercased by the font's lookup. Centred when it
    /// fits the window, otherwise left for the controller to scroll with `setMessageOffset`.
    func showMessage(_ text: String, isError: Bool = false) {
        let slot = layout.text.message
        guard let font = assets.fonts[slot.font] else { return }
        let color = PillLayout.color(hex: isError ? layout.colors.error : layout.colors.text)
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
            x: CGFloat(offset) * Self.artScale, y: 0,
            width: CGFloat(messageWidth) * Self.artScale, height: messageClip.bounds.height
        )
    }
}
