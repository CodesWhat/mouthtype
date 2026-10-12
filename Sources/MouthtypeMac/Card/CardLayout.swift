import CoreGraphics
import Foundation

/// The delivery card's measurements and the maths behind them, with no views in it. Coordinates have their origin at
/// the card's top left. The face is 224 pt wide; the transcript grows to five lines and then scrolls inside.
enum CardLayout {
    static let width: CGFloat = 224
    static let insets = (top: CGFloat(11), side: CGFloat(12), bottom: CGFloat(12))
    static let dot: CGFloat = 6
    static let dismissSize: CGFloat = 20
    static let headerGap: CGFloat = 7
    static let rowHeight: CGFloat = 20
    static let transcriptTop: CGFloat = 8
    static let transcriptBottom: CGFloat = 11
    static let maxTranscriptLines = 5
    static let buttonHeight: CGFloat = 26
    static let minButtonWidth: CGFloat = 64
    static let buttonPadding: CGFloat = 14
    static let buttonGap: CGFloat = 6
    /// The countdown bar lies along the card's bottom edge, over the bottom padding, clipped to the card's shape.
    static let barHeight: CGFloat = 3
    /// Room around the face for the shadow.
    static let shadowMargin: CGFloat = 16
    /// The gap between the card's bottom and the pill's top.
    static let pillGap: CGFloat = 8
    static let cornerRadius: CGFloat = 16

    static var contentWidth: CGFloat { width - 2 * insets.side }
    /// What the reason text gets: the row less the dot, the dismiss control and the gaps on each side of the text.
    static var headerTextWidth: CGFloat { contentWidth - dot - dismissSize - 2 * headerGap }

    struct Input {
        /// Height of the reason text laid out at `headerTextWidth`, and of one line of it.
        var headerTextHeight: CGFloat
        var headerLineHeight: CGFloat
        /// Height of the whole transcript laid out at `contentWidth`, nil when the card has none.
        var transcriptTextHeight: CGFloat?
        var transcriptLineHeight: CGFloat
        /// Intrinsic label width of each button, in order.
        var buttonLabelWidths: [CGFloat]
        var hasCountdownBar: Bool
    }

    struct Frames: Equatable {
        var size: CGSize
        var dot: CGRect
        var header: CGRect
        var dismiss: CGRect
        var transcript: CGRect?
        /// The transcript is taller than five lines, so it scrolls inside its frame.
        var transcriptScrolls: Bool
        var buttons: [CGRect]
        var bar: CGRect?
    }

    static func buttonWidth(label: CGFloat) -> CGFloat {
        max(minButtonWidth, ceil(label) + 2 * buttonPadding)
    }

    static func make(_ input: Input) -> Frames {
        let left = insets.side
        let right = width - insets.side
        let headerHeight = max(rowHeight, ceil(input.headerTextHeight))
        var y = insets.top

        let firstLine = max(rowHeight, input.headerLineHeight)
        let dot = CGRect(x: left, y: y + firstLine / 2 - Self.dot / 2, width: Self.dot, height: Self.dot)
        let textX = left + Self.dot + headerGap
        let header = CGRect(
            x: textX, y: y + (headerHeight - ceil(input.headerTextHeight)) / 2,
            width: headerTextWidth, height: ceil(input.headerTextHeight)
        )
        let dismiss = CGRect(x: right - dismissSize, y: y, width: dismissSize, height: dismissSize)
        y += headerHeight

        var transcript: CGRect?
        var scrolls = false
        if let textHeight = input.transcriptTextHeight {
            let cap = CGFloat(maxTranscriptLines) * input.transcriptLineHeight
            scrolls = textHeight > cap + 0.5
            y += transcriptTop
            transcript = CGRect(x: left, y: y, width: contentWidth, height: ceil(scrolls ? cap : textHeight))
            y += transcript?.height ?? 0
        }
        y += transcriptBottom

        var buttons: [CGRect] = []
        var x = right
        for label in input.buttonLabelWidths.reversed() {
            let w = buttonWidth(label: label)
            x -= w
            buttons.insert(CGRect(x: x, y: y, width: w, height: buttonHeight), at: 0)
            x -= buttonGap
        }
        y += buttonHeight

        y += insets.bottom
        let bar = input.hasCountdownBar ? CGRect(x: 0, y: y - barHeight, width: width, height: barHeight) : nil
        return Frames(
            size: CGSize(width: width, height: y), dot: dot, header: header, dismiss: dismiss,
            transcript: transcript, transcriptScrolls: scrolls, buttons: buttons, bar: bar
        )
    }

    /// The seconds shown on the Undo button: whole seconds left, rounded up, never below 0.
    static func countdownLabel(remaining: TimeInterval) -> String {
        "\(max(0, Int(ceil(max(0, remaining)))))s"
    }

    /// The bar's fill, 1 at the start down to 0.
    static func countdownFraction(remaining: TimeInterval, total: TimeInterval) -> CGFloat {
        guard total > 0 else { return 0 }
        return CGFloat(min(1, max(0, remaining / total)))
    }

    /// Where the card's panel sits: centred over `pillMidX`, its face `pillGap` above `pillTop`, nudged to stay on
    /// `visible`. The panel carries `shadowMargin` around the face.
    static func panelFrame(face: CGSize, pillMidX: CGFloat, pillTop: CGFloat, visible: CGRect) -> CGRect {
        let size = CGSize(width: face.width + 2 * shadowMargin, height: face.height + 2 * shadowMargin)
        var x = pillMidX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        var y = pillTop + pillGap - shadowMargin
        y = min(y, visible.maxY - size.height)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: size.width, height: size.height)
    }
}
