import AppKit

/// The two cancel and stop controls a locked hands-free pill shows.
enum PillControl: Hashable, Sendable {
    case cancel, stop
}

enum PillSkinKind: String, CaseIterable, Sendable {
    case classic, hifi

    static let `default` = PillSkinKind.classic

    var title: String {
        switch self {
        case .classic: "Classic"
        case .hifi: "Hi-Fi"
        }
    }
}

enum PillSkinPreference {
    static let key = "pillSkin"

    static func current(_ defaults: UserDefaults = .standard) -> PillSkinKind {
        defaults.string(forKey: key).flatMap(PillSkinKind.init(rawValue:)) ?? .default
    }

    static func set(_ kind: PillSkinKind, in defaults: UserDefaults = .standard) {
        defaults.set(kind.rawValue, forKey: key)
    }
}

/// The size setting. Automatic is decided each time the pill shows, from the screen it lands on.
enum PillSize: String, CaseIterable, Sendable {
    case automatic, standard, large

    static let `default` = PillSize.automatic
    /// A visible frame at least this wide (in points) gets the large pill under Automatic.
    static let largeScreenWidth: CGFloat = 2000

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .standard: "Standard"
        case .large: "Large"
        }
    }

    func resolved(visibleWidth: CGFloat) -> PillScale {
        switch self {
        case .standard: .standard
        case .large: .large
        case .automatic: visibleWidth >= Self.largeScreenWidth ? .large : .standard
        }
    }
}

/// What a size setting resolves to: the integer multiple every length in the pill is drawn at.
enum PillScale: Int, Sendable {
    case standard = 1, large = 2

    var factor: CGFloat { CGFloat(rawValue) }
}

enum PillSizePreference {
    static let key = "pillSize"
    /// The Hi-Fi only setting this replaced: 1 standard, 2 large.
    static let legacyKey = "hiFiPillSize"

    static func current(_ defaults: UserDefaults = .standard) -> PillSize {
        migrateLegacy(defaults)
        return defaults.string(forKey: key).flatMap(PillSize.init(rawValue:)) ?? .default
    }

    static func set(_ size: PillSize, in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: legacyKey)
        defaults.set(size.rawValue, forKey: key)
    }

    /// A saved Hi-Fi size of large becomes the large pill and anything else becomes Automatic. The old key goes either
    /// way, and a choice already made under the new key is left alone.
    static func migrateLegacy(_ defaults: UserDefaults) {
        guard defaults.object(forKey: legacyKey) != nil else { return }
        if defaults.object(forKey: key) == nil {
            defaults.set((defaults.integer(forKey: legacyKey) == 2 ? PillSize.large : .automatic).rawValue, forKey: key)
        }
        defaults.removeObject(forKey: legacyKey)
    }
}

/// Where the pill sits in its panel. Both skins draw inside the same fixed panel, anchored on its bottom margin, so
/// switching skins never moves or resizes the window.
enum PillGeometry {
    static let horizontalMargin: CGFloat = 24
    static let verticalMargin: CGFloat = 20
    /// Tall enough for a message wrapped onto many lines; the panel is click-through, so spare room costs nothing.
    static let maxPillSize = CGSize(width: ClassicPillLayout.messageCap, height: 160)
    static let panelSize = panelSize(for: .standard)

    /// The panel grows with the pill, so a large message has the same room a standard one does.
    static func panelSize(for scale: PillScale) -> CGSize {
        CGSize(
            width: maxPillSize.width * scale.factor + 2 * horizontalMargin,
            height: maxPillSize.height * scale.factor + 2 * verticalMargin
        )
    }
}

/// Hit-testing for the two controls, pure so both skins share it.
enum PillHit {
    /// The smallest click target, whatever the drawn control measures.
    static let minTarget: CGFloat = 24

    /// `drawn` grown about its centre to at least `minTarget` square.
    static func target(for drawn: CGRect) -> CGRect {
        let width = max(drawn.width, minTarget)
        let height = max(drawn.height, minTarget)
        return CGRect(x: drawn.midX - width / 2, y: drawn.midY - height / 2, width: width, height: height)
    }

    /// The control under `point`. Padded targets can overlap (the hi-fi caps are 3 pt apart), so the nearer centre wins.
    static func control(at point: CGPoint, frames: [PillControl: CGRect]) -> PillControl? {
        frames
            .filter { target(for: $0.value).contains(point) }
            .min { distance(point, $0.value) < distance(point, $1.value) }?
            .key
    }

    private static func distance(_ point: CGPoint, _ frame: CGRect) -> CGFloat {
        hypot(point.x - frame.midX, point.y - frame.midY)
    }
}

/// What a look has to do to be the pill. The controller owns state, timing and placement; a skin only draws.
@MainActor
protocol PillSkinView: NSView {
    var isLocked: Bool { get }
    /// How far the current message has to scroll, 0 when it sits still.
    var messageScrollDistance: Int { get }
    /// Drawn frames of the controls in this view's coordinates; empty unless a locked recording is showing.
    var controlFrames: [PillControl: CGRect] { get }

    func showRecording(locked: Bool)
    func beginProcessing()
    /// `overRecording` keeps the recording's lock look underneath, for a notice that gives way to it again.
    func showMessage(_ message: PillMessage, overRecording: Bool)
    /// The text font setting changed. Skins that draw bitmap text ignore it.
    func applyTypography(_ typography: Typography)
    /// Each frame while recording: the smoothed 0...1 level of every bar.
    func showFractions(_ fractions: [Float])
    /// Each frame while processing.
    func updateProcessing(time: TimeInterval)
    /// Seconds into the recording, nil outside one.
    func setElapsed(_ seconds: TimeInterval?)
    func setMessageOffset(_ offset: Int)
    func setHovered(_ control: PillControl?)
    func setPressed(_ control: PillControl?)
    func appear(reduceMotion: Bool)
    func disappear(reduceMotion: Bool, completion: @escaping @MainActor () -> Void)
}

/// The panel's content view: holds the skin and takes the click on a control. It only answers hit tests over a
/// control, and the controller only lets the panel see the mouse while the pointer is over one.
@MainActor
final class PillHostView: NSView {
    var controlAt: (CGPoint) -> PillControl? = { _ in nil }
    var onPress: (PillControl?) -> Void = { _ in }
    var onActivate: (PillControl) -> Void = { _ in }
    private var pressed: PillControl?

    override var acceptsFirstResponder: Bool { false }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        controlAt(convert(point, from: superview)) == nil ? nil : self
    }

    override func mouseDown(with event: NSEvent) {
        pressed = controlAt(convert(event.locationInWindow, from: nil))
        onPress(pressed)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressed else { return }
        let over = controlAt(convert(event.locationInWindow, from: nil)) == pressed
        onPress(over ? pressed : nil)
    }

    override func mouseUp(with event: NSEvent) {
        guard let pressed else { return }
        self.pressed = nil
        let over = controlAt(convert(event.locationInWindow, from: nil)) == pressed
        onPress(nil)
        if over { onActivate(pressed) }
    }

    func skinReplaced() { pressed = nil }
}
