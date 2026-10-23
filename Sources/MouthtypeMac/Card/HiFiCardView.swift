import AppKit

/// Draws a card control from art: composed at 1 art pixel per pixel, then magnified at the integer card scale with no
/// smoothing. Not flipped, so the image draws upright.
@MainActor
private func drawArt(_ image: CGImage, in bounds: CGRect) {
    guard let context = NSGraphicsContext.current?.cgContext else { return }
    context.interpolationQuality = .none
    context.setShouldAntialias(false)
    context.draw(image, in: bounds)
}

/// A bevelled pixel button: the cap's 9-slice with the label engraved live in the 5x7 face. The first button of a card
/// is lit in the readout colour, the rest are engraved grey; the pressed cap drops and the label sinks with it.
@MainActor
final class HiFiButtonView: CardControlView {
    var assets: HiFiCardAssets?
    /// The label as drawn: uppercase, in the face's alphabet.
    var label = ""
    var isPrimary = true
    /// The readout colour of the lit label, an art hex string.
    var litHex = "#ffb02e"

    override var isFlipped: Bool { false }

    /// The art size of the button, in art pixels.
    private var artSize: (w: Int, h: Int) { (max(1, Int((bounds.width / k).rounded())), max(1, Int((bounds.height / k).rounded()))) }

    /// The composed button at 1x, for drawing and for tests.
    func artImage() -> CGImage? {
        guard let assets, let slices = assets.slices(of: "button_up") else { return nil }
        let (w, h) = artSize
        guard let canvas = HiFiCanvas(width: w, height: h) else { return nil }
        canvas.nineSlice(isPressed ? assets.buttonDown : assets.buttonUp, slices: slices, in: .init(x: 0, y: 0, w: w, h: h))
        let base = isPrimary ? litHex : assets.spec.colors.engraveHi
        let color = isHovered && !isPressed ? HiFiCanvas.mix(base, "#ffffff", 0.35) : PillLayout.color(hex: base)
        if let text = assets.font5.image(for: label, color: color) {
            let dy = isPressed ? assets.metrics.button.labelPressedDy : 0
            canvas.draw(text, x: (w - text.width) / 2, y: (h - text.height) / 2 + dy)
        }
        return canvas.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = artImage() { drawArt(image, in: bounds) }
    }

    override func accessibilityPerformPress() -> Bool {
        guard isActive else { return false }
        onClick?()
        return true
    }
}

/// The title bar's pixel close button, in a hit area (at least 24 pt square) larger than the art so it is easy to land on.
@MainActor
final class HiFiCloseView: CardControlView {
    var assets: HiFiCardAssets?
    /// Where the art sits in the hit area, in art pixels from its top-left.
    var artOrigin = (x: 0, y: 0)

    override var isFlipped: Bool { false }

    func artImage() -> CGImage? {
        guard let assets else { return nil }
        let m = assets.metrics
        guard let canvas = HiFiCanvas(width: m.close.hitW, height: m.close.hitH) else { return nil }
        canvas.draw(isPressed ? assets.closeDown : assets.closeUp, x: artOrigin.x, y: artOrigin.y)
        return canvas.makeImage()
    }

    override func draw(_ dirtyRect: NSRect) {
        if let image = artImage() { drawArt(image, in: bounds) }
    }

    override func accessibilityPerformPress() -> Bool {
        onClick?()
        return true
    }
}

/// Carries the original-case text for VoiceOver over the readout the pixels draw.
private final class HiFiReadoutProxy: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

/// The Hi-Fi delivery card: a brushed-metal window with a pixel title bar (status LED, header, close), the transcript
/// in an amber VFD panel in the 5x7 face, bevelled pixel buttons, and a pixel countdown bar in the panel. The window is
/// composed at 1 art pixel per pixel and magnified by the pill's scale (1 or 2), so it is always whole pixels. All of it
/// is display: the buttons run the same actions on the original text.
@MainActor
final class HiFiCardView: NSView {
    var onAction: (@MainActor (CardAction) -> Void)?
    var onDismiss: (@MainActor () -> Void)?

    let assets: HiFiCardAssets
    private let close = HiFiCloseView()
    private let proxy = HiFiReadoutProxy()
    private var buttons: [(action: CardAction, view: HiFiButtonView)] = []

    private(set) var frames: HiFiCardLayout.Frames?
    private(set) var title = ""
    /// The VFD's lines as drawn, all of them, including those scrolled out of view.
    private(set) var lines: [HiFiCardText.Line] = []
    private(set) var readout = PillReadoutColour.default
    private(set) var faceImage: CGImage?
    private(set) var scrollOffset = 0
    private var state: CardViewState?
    private var k: CGFloat = 1
    private var fraction: CGFloat?
    private var scrollRemainder: CGFloat = 0

    var faceSize: CGSize { frames.map { CGSize(width: CGFloat($0.width) * k, height: CGFloat($0.height) * k) } ?? .zero }
    var buttonViews: [CardAction: HiFiButtonView] { Dictionary(uniqueKeysWithValues: buttons.map { ($0.action, $0.view) }) }
    var closeView: HiFiCloseView { close }
    var vfdLinesVisible: Int { frames?.visibleLines ?? 0 }
    /// What VoiceOver reads for the readout: the original-case text, not the capitals the pixels draw.
    var spokenText: String { proxy.accessibilityLabel() ?? "" }

    override var isFlipped: Bool { false }
    override var isOpaque: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(assets: HiFiCardAssets) {
        self.assets = assets
        super.init(frame: .zero)
        close.assets = assets
        close.onClick = { [weak self] in self?.onDismiss?() }
        close.setAccessibilityLabel("Dismiss")
        close.setAccessibilityRole(.button)
        close.setAccessibilityElement(true)
        addSubview(close)
        proxy.setAccessibilityElement(true)
        proxy.setAccessibilityRole(.staticText)
        addSubview(proxy)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    // MARK: Colours

    private var palette: PillReadoutColour.Palette { readout.palette(base: assets.pill.layout.colors) }
    var textColor: CGColor { PillLayout.color(hex: palette.text) }
    var emphasisColor: CGColor { PillLayout.color(hex: palette.hot) }
    /// The error ink: the palette's own, which a readout colour never equals.
    var errorColor: CGColor { PillLayout.color(hex: palette.error) }

    private func accentHex(_ kind: DeliveryCard.Kind) -> String {
        kind.isQuestion ? palette.hot : kind.isQuiet ? palette.normal : palette.error
    }

    /// The status LED's colour: the error ink for a failure, the readout's quiet and question tones otherwise.
    func accentColor(for kind: DeliveryCard.Kind) -> CGColor { PillLayout.color(hex: accentHex(kind)) }

    // MARK: Render

    /// Whether the pixel face can show all of `card`'s text as written. When it can't (other scripts, symbols), the
    /// delivery draws on the Classic card instead, so the user's text is never turned into `?`.
    static func canRender(_ card: DeliveryCard, assets: HiFiCardAssets) -> Bool {
        let lines = card.header.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        var texts = Array(lines.dropFirst())
        if let transcript = card.transcript { texts.append(transcript) }
        if let pair = card.pair { texts += [pair.heard, pair.corrected] }
        return HiFiCardText.canDraw(lines.first ?? "", metrics: assets.font3.metrics)
            && texts.allSatisfy { HiFiCardText.canDraw($0, metrics: assets.font5.metrics) }
    }

    /// The labels a button can show, the current one first, then the others it may change to (for sizing).
    static func labels(for action: CardAction, in state: CardViewState, remaining: TimeInterval?) -> [String] {
        if state.copied && action == .copy { return ["Copied"] }
        if state.copied && action == .save { return ["Saved"] }
        if state.copied && action == .forget { return ["Forgotten"] }
        switch action {
        case .undo:
            let total = state.card.countdown ?? DeliveryCard.undoWindow
            return ["Undo \(CardLayout.countdownLabel(remaining: remaining ?? total))", "Undo \(CardLayout.countdownLabel(remaining: total))"]
        case .copy: return ["Copy", "Copied"]
        case .save: return ["Save", "Saved"]
        case .forget: return ["Forget", "Forgotten"]
        default: return [action.title]
        }
    }

    /// Lays out and draws `state` at `scale`; `remaining` and `fraction` are the countdown's seconds left and bar fill.
    /// Returns the card's size.
    @discardableResult
    func render(_ new: CardViewState, scale: PillScale, readout: PillReadoutColour, remaining: TimeInterval?, fraction: CGFloat?) -> CGSize {
        let isNew = state?.card != new.card
        state = new
        k = scale.factor
        self.readout = readout
        self.fraction = fraction
        let m = assets.metrics
        let m3 = assets.font3.metrics, m5 = assets.font5.metrics
        let card = new.card

        let headerLines = card.header.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        let titleLines = HiFiCardText.wrap(
            [(HiFiCardText.display(headerLines.first ?? "", metrics: m3), .normal)], metrics: m3, maxWidth: HiFiCardLayout.titleMaxWidth(m)
        )
        title = titleLines.first.map(HiFiCardText.text(of:)) ?? ""
        let overflow = titleLines.dropFirst().map(HiFiCardText.text(of:))
        let detail = (overflow + headerLines.dropFirst().map { HiFiCardText.display($0, metrics: m5) }).joined(separator: "\n")

        var pieces: [(text: String, style: HiFiCardText.Style)] = []
        if !detail.isEmpty { pieces.append((detail, .detail)) }
        var body: [(text: String, style: HiFiCardText.Style)] = []
        if let text = card.transcript {
            body = [(HiFiCardText.display(text.trimmingCharacters(in: .whitespacesAndNewlines), metrics: m5), .normal)]
        } else if let pair = card.pair {
            body = [(HiFiCardText.display("\(pair.heard) \u{2192} ", metrics: m5), .normal), (HiFiCardText.display(pair.corrected, metrics: m5), .emphasis)]
        }
        if !pieces.isEmpty && !body.isEmpty { pieces.append(("\n", .normal)) }
        pieces += body
        lines = HiFiCardText.wrap(pieces, metrics: m5, maxWidth: HiFiCardLayout.textMaxWidth(m))
        if isNew { scrollOffset = 0 }
        scrollOffset = max(0, min(scrollOffset, lines.count - m.maxLines))

        let labelWidths = card.actions.map { action in
            Self.labels(for: action, in: new, remaining: remaining)
                .map { m5.width(of: HiFiCardText.display($0, metrics: m5)) }.max() ?? 0
        }
        let layout = HiFiCardLayout.make(
            .init(
                titleWidth: m3.width(of: title), lineCount: lines.count, lineHeight: m5.cellHeight,
                hasBar: card.countdown != nil, buttonLabelWidths: labelWidths
            ), m)
        frames = layout
        let size = faceSize
        setFrameSize(size)

        close.k = k
        close.artOrigin = (layout.close.x - layout.closeHit.x, layout.close.y - layout.closeHit.y)
        close.frame = viewRect(layout.closeHit)
        close.needsDisplay = true

        for entry in buttons { entry.view.removeFromSuperview() }
        buttons = []
        for (index, action) in card.actions.enumerated() where index < layout.buttons.count {
            let view = HiFiButtonView(frame: viewRect(layout.buttons[index]))
            view.assets = assets
            view.k = k
            view.isPrimary = index == 0
            view.litHex = palette.text
            view.isActive = !new.copied
            view.onClick = { [weak self] in self?.onAction?(action) }
            addSubview(view)
            buttons.append((action, view))
        }
        refreshButtonLabels(remaining: remaining)

        proxy.frame = layout.vfd.map(viewRect) ?? .zero
        setAccessibilityLabel(headerLines.first ?? card.header)
        var spoken = Array(headerLines.dropFirst())
        if let text = card.transcript { spoken.append(text) }
        if let pair = card.pair { spoken.append("\(pair.heard) to \(pair.corrected)") }
        proxy.setAccessibilityLabel(spoken.joined(separator: ". "))

        refreshFace()
        return size
    }

    /// Re-draws the countdown: the seconds on Undo, and the bar at `fraction`.
    func tick(remaining: TimeInterval?, fraction: CGFloat?) {
        guard let state else { return }
        self.fraction = fraction
        if !state.copied { refreshButtonLabels(remaining: remaining) }
        if frames?.bar != nil { refreshFace() }
    }

    private func refreshButtonLabels(remaining: TimeInterval?) {
        guard let state else { return }
        let m5 = assets.font5.metrics
        for entry in buttons {
            let current = Self.labels(for: entry.action, in: state, remaining: remaining)[0]
            entry.view.label = HiFiCardText.display(current, metrics: m5)
            entry.view.setAccessibilityLabel(current)
            entry.view.setAccessibilityRole(.button)
            entry.view.setAccessibilityElement(true)
            entry.view.needsDisplay = true
        }
    }

    /// A rect in art pixels (top-left origin) as a frame in this view.
    private func viewRect(_ rect: PillLayout.Rect) -> CGRect {
        guard let frames else { return .zero }
        return CGRect(x: CGFloat(rect.x) * k, y: CGFloat(frames.height - rect.y - rect.h) * k, width: CGFloat(rect.w) * k, height: CGFloat(rect.h) * k)
    }

    // MARK: Scrolling

    /// Scrolls the VFD's text by whole lines when it has more than five; no-op otherwise.
    func scrollLines(by delta: Int) {
        let limit = max(0, lines.count - assets.metrics.maxLines)
        let next = max(0, min(limit, scrollOffset + delta))
        guard next != scrollOffset else { return }
        scrollOffset = next
        refreshFace()
    }

    override func scrollWheel(with event: NSEvent) {
        guard lines.count > assets.metrics.maxLines else { super.scrollWheel(with: event); return }
        scrollRemainder += event.hasPreciseScrollingDeltas ? event.scrollingDeltaY / (9 * k) : event.scrollingDeltaY
        let steps = Int(scrollRemainder)
        guard steps != 0 else { return }
        scrollRemainder -= CGFloat(steps)
        scrollLines(by: -steps)
    }

    // MARK: Drawing

    private func refreshFace() {
        faceImage = composeFace()
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        if let faceImage { drawArt(faceImage, in: bounds) }
    }

    /// The window at 1x: frame, title plate with its LED and header, and the VFD with its text and bar.
    private func composeFace() -> CGImage? {
        guard let frames, let state, let canvas = HiFiCanvas(width: frames.width, height: frames.height),
            let frameSlices = assets.slices(of: "frame")
        else { return nil }
        let c = assets.spec.colors, m = assets.metrics
        let p = palette
        let kind = state.card.kind
        let isFailure = !kind.isQuestion && !kind.isQuiet
        canvas.nineSlice(assets.frame, slices: frameSlices, in: .init(x: 0, y: 0, w: frames.width, h: frames.height))

        canvas.fill(frames.plate, PillLayout.color(hex: c.metal))
        canvas.fill(frames.plate.x, frames.plate.y, frames.plate.w, 1, HiFiCanvas.mix(c.metal, c.metalHi, 0.4))
        if let led = assets.pill.sprites["led_on"], let tinted = HiFiCanvas.tinted(led, accentColor(for: kind)) {
            canvas.draw(tinted, x: frames.led.x, y: frames.led.y)
            canvas.fill(frames.led.x + 1, frames.led.y + 1, 1, 1, HiFiCanvas.mix(accentHex(kind), "#ffffff", 0.55))
        }
        if let ear = assets.font5.image(for: String(HiFiCardText.ear), color: PillLayout.color(hex: c.engraveHi)) {
            canvas.draw(ear, x: frames.ear.x, y: frames.ear.y)
        }
        let titleInk = isFailure ? p.error : c.engraveHi
        if let text = assets.font3.image(for: title, color: PillLayout.color(hex: titleInk)) {
            canvas.draw(text, x: Int(frames.titleOrigin.x), y: Int(frames.titleOrigin.y))
        }

        if let vfd = frames.vfd, let vfdSlices = assets.slices(of: "vfd") {
            canvas.nineSlice(assets.vfd, slices: vfdSlices, in: vfd)
            let cell = assets.font5.metrics.cellHeight
            let step = cell + m.vfd.lineGap
            let visible = lines.dropFirst(scrollOffset).prefix(frames.visibleLines)
            for (row, line) in visible.enumerated() {
                var drawn = ""
                for run in line {
                    let hex: String
                    switch run.style {
                    case .normal: hex = p.text
                    case .emphasis: hex = p.hot
                    case .detail: hex = isFailure ? p.error : p.normal
                    }
                    let x = Int(frames.textOrigin.x) + (drawn.isEmpty ? 0 : assets.font5.width(of: drawn) + assets.font5.metrics.gap)
                    if let text = assets.font5.image(for: run.text, color: PillLayout.color(hex: hex)) {
                        canvas.draw(text, x: x, y: Int(frames.textOrigin.y) + row * step)
                    }
                    drawn += run.text
                }
            }
            if lines.count > m.maxLines {
                // A one-pixel thumb along the panel's right edge says there is more above or below.
                let track = frames.visibleLines * step - m.vfd.lineGap
                let thumb = max(3, track * m.maxLines / lines.count)
                let travel = track - thumb
                let top = Int(frames.textOrigin.y) + (travel * scrollOffset) / max(1, lines.count - m.maxLines)
                canvas.fill(vfd.x + vfd.w - m.vfd.ring - 2, top, 1, thumb, HiFiCanvas.mix(p.normal, c.vfdBg, 0.45))
            }
            if let bar = frames.bar {
                let count = (bar.w + m.vfd.barSegGap) / (m.vfd.barSegW + m.vfd.barSegGap)
                let lit = HiFiCardLayout.litSegments(fraction: fraction ?? 0, count: count)
                let on = PillLayout.color(hex: p.normal), off = HiFiCanvas.mix(p.normal, c.vfdBg, 0.85)
                for index in 0..<count {
                    canvas.fill(bar.x + index * (m.vfd.barSegW + m.vfd.barSegGap), bar.y, m.vfd.barSegW, bar.h, index < lit ? on : off)
                }
            }
        }
        return canvas.makeImage()
    }
}
