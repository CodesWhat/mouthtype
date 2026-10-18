import CoreGraphics
import Foundation

/// The delivery card's measurements and the maths behind them, with no views in it. Coordinates have their origin at
/// the card's top left. The face is 224 pt wide at the Standard pill size and twice that at Large (every length, the
/// type included, scales with the pill); the transcript grows to five lines and then scrolls inside.
enum CardLayout {
    static let width: CGFloat = 224
    static let insets = (top: CGFloat(11), side: CGFloat(12), bottom: CGFloat(12))
    static let dot: CGFloat = 6
    /// The pill's own minimum click target.
    static let dismissSize: CGFloat = 24
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

    static var contentWidth: CGFloat { contentWidth(scale: 1) }
    /// What the reason text gets: the row less the dot, the dismiss control and the gaps on each side of the text.
    static var headerTextWidth: CGFloat { headerTextWidth(scale: 1) }

    static func contentWidth(scale k: CGFloat) -> CGFloat { (width - 2 * insets.side) * k }

    /// The header's room at `scale`. A card without a status dot (the squircle cards keep it in the readout row) gives
    /// the text the dot's width too.
    static func headerTextWidth(scale k: CGFloat, showsDot: Bool = true) -> CGFloat {
        contentWidth(scale: k) - (showsDot ? (dot + headerGap) * k : 0) - (dismissSize + headerGap) * k
    }

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

    static func buttonWidth(label: CGFloat, scale k: CGFloat = 1) -> CGFloat {
        max(minButtonWidth * k, ceil(label) + 2 * buttonPadding * k)
    }

    /// The card at `scale` times the Standard size. `input` is measured at that scale already: text laid out at
    /// `headerTextWidth(scale:)` and `contentWidth(scale:)` in the scaled fonts.
    static func make(_ input: Input, scale k: CGFloat = 1, showsDot: Bool = true) -> Frames {
        let width = Self.width * k
        let left = insets.side * k
        let right = width - left
        let rowHeight = Self.rowHeight * k
        let dismissSize = Self.dismissSize * k
        let headerHeight = max(rowHeight, ceil(input.headerTextHeight))
        var y = insets.top * k

        let firstLine = max(rowHeight, input.headerLineHeight)
        let dotSize = showsDot ? Self.dot * k : 0
        let dot = CGRect(x: left, y: y + firstLine / 2 - dotSize / 2, width: dotSize, height: dotSize)
        let textX = left + (showsDot ? (Self.dot + headerGap) * k : 0)
        let header = CGRect(
            x: textX, y: y + (headerHeight - ceil(input.headerTextHeight)) / 2,
            width: headerTextWidth(scale: k, showsDot: showsDot), height: ceil(input.headerTextHeight)
        )
        // Centred on the first line like the dot, so the taller control reaches into the padding, not the content.
        let dismiss = CGRect(x: right - dismissSize, y: y + firstLine / 2 - dismissSize / 2, width: dismissSize, height: dismissSize)
        y += headerHeight

        var transcript: CGRect?
        var scrolls = false
        if let textHeight = input.transcriptTextHeight {
            let cap = CGFloat(maxTranscriptLines) * input.transcriptLineHeight
            scrolls = textHeight > cap + 0.5
            y += transcriptTop * k
            transcript = CGRect(x: left, y: y, width: contentWidth(scale: k), height: ceil(scrolls ? cap : textHeight))
            y += transcript?.height ?? 0
        }
        if !input.buttonLabelWidths.isEmpty { y += transcriptBottom * k }

        var buttons: [CGRect] = []
        var x = right
        for label in input.buttonLabelWidths.reversed() {
            let w = buttonWidth(label: label, scale: k)
            x -= w
            buttons.insert(CGRect(x: x, y: y, width: w, height: buttonHeight * k), at: 0)
            x -= buttonGap * k
        }
        if !buttons.isEmpty { y += buttonHeight * k }

        y += insets.bottom * k
        let bar = input.hasCountdownBar ? CGRect(x: 0, y: y - barHeight * k, width: width, height: barHeight * k) : nil
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
    static func panelFrame(face: CGSize, pillMidX: CGFloat, pillTop: CGFloat, visible: CGRect, scale k: CGFloat = 1) -> CGRect {
        let shadowMargin = Self.shadowMargin * k, pillGap = Self.pillGap * k
        let size = CGSize(width: face.width + 2 * shadowMargin, height: face.height + 2 * shadowMargin)
        var x = pillMidX - size.width / 2
        x = min(max(x, visible.minX), max(visible.minX, visible.maxX - size.width))
        var y = pillTop + pillGap - shadowMargin
        y = min(y, visible.maxY - size.height)
        return CGRect(x: x.rounded(.down), y: y.rounded(.down), width: size.width, height: size.height)
    }
}
