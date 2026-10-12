import AppKit
import QuartzCore

/// The pill, drawn with plain layers so a frame update is a handful of bounds changes. The view never takes
/// events, and the panel around it is click-through anyway.
@MainActor
final class PillView: NSView {
    static let pillSize = CGSize(width: 97, height: 28)
    static let barWidth: CGFloat = 2.25
    static let barPitch: CGFloat = 4.25
    static let messageFont = NSFont.systemFont(ofSize: 12)
    static let messagePadding: CGFloat = 14

    static let fill = NSColor(hex: 0x1A1A1A)
    static let stroke = NSColor(hex: 0x4D4A42)
    static let ink = NSColor(hex: 0xFFFFEB)

    /// What the pill can show at most, so the panel can be one fixed size.
    let maxPillWidth: CGFloat

    /// Holds the pill and is what the show and hide animations scale and fade.
    let container = CALayer()
    private let pill = CALayer()
    private let bars: [CALayer]
    private let text = CATextLayer()

    init(frame: NSRect, maxPillWidth: CGFloat) {
        self.maxPillWidth = maxPillWidth
        self.bars = (0..<BarModel.barCount).map { _ in CALayer() }
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = .clear

        container.frame = bounds
        container.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        container.opacity = 0
        container.transform = CATransform3DMakeScale(0.85, 0.85, 1)
        layer?.addSublayer(container)

        pill.backgroundColor = Self.fill.cgColor
        pill.borderColor = Self.stroke.cgColor
        pill.borderWidth = 1
        container.addSublayer(pill)

        for bar in bars {
            bar.backgroundColor = Self.ink.cgColor
            bar.cornerRadius = Self.barWidth / 2
            pill.addSublayer(bar)
        }

        text.font = Self.messageFont
        text.fontSize = Self.messageFont.pointSize
        text.foregroundColor = Self.ink.cgColor
        text.alignmentMode = .center
        text.truncationMode = .end
        text.isWrapped = false
        text.isHidden = true
        pill.addSublayer(text)

        setBarsHeights([CGFloat](repeating: BarModel.minHeight, count: BarModel.barCount))
        setPillWidth(Self.pillSize.width, animated: false)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        layer?.contentsScale = scale
        text.contentsScale = scale
        for layer in [container, pill] + bars { layer.contentsScale = scale }
    }

    func showBars(_ heights: [CGFloat]) {
        if !text.isHidden {
            setMessage(nil)
            setPillWidth(Self.pillSize.width, animated: false)
        }
        setBarsHeights(heights)
    }

    /// Replaces the bars with one line of text and widens the pill to fit it.
    func showMessage(_ message: String, animated: Bool) {
        let width = Self.pillWidth(forMessage: message, max: maxPillWidth)
        setMessage(message)
        setPillWidth(width, animated: animated)
    }

    static func pillWidth(forMessage message: String, max maxWidth: CGFloat) -> CGFloat {
        let textWidth = (message as NSString).size(withAttributes: [.font: messageFont]).width
        return min(maxWidth, Swift.max(pillSize.width, ceil(textWidth) + messagePadding * 2))
    }

    private func setMessage(_ message: String?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        text.isHidden = message == nil
        bars.forEach { $0.isHidden = message != nil }
        if let message {
            text.string = message
        }
        CATransaction.commit()
    }

    private func setBarsHeights(_ heights: [CGFloat]) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let midX = pill.bounds.width / 2
        let midY = pill.bounds.height / 2
        let count = CGFloat(bars.count)
        for (i, bar) in bars.enumerated() {
            let height = i < heights.count ? heights[i] : BarModel.minHeight
            bar.bounds = CGRect(x: 0, y: 0, width: Self.barWidth, height: height)
            bar.position = CGPoint(x: midX + (CGFloat(i) - (count - 1) / 2) * Self.barPitch, y: midY)
        }
        CATransaction.commit()
    }

    private func setPillWidth(_ width: CGFloat, animated: Bool) {
        let size = CGSize(width: width, height: Self.pillSize.height)
        CATransaction.begin()
        if animated {
            CATransaction.setAnimationDuration(0.15)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: .easeOut))
        } else {
            CATransaction.setDisableActions(true)
        }
        pill.bounds = CGRect(origin: .zero, size: size)
        pill.cornerRadius = size.height / 2
        pill.position = CGPoint(x: bounds.midX, y: bounds.midY)
        let lineHeight = ceil(Self.messageFont.ascender - Self.messageFont.descender + Self.messageFont.leading)
        text.frame = CGRect(
            x: Self.messagePadding, y: (size.height - lineHeight) / 2,
            width: size.width - Self.messagePadding * 2, height: lineHeight
        )
        CATransaction.commit()
        if text.isHidden { setBarsHeights(bars.map { $0.bounds.height }) }
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(
            srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
