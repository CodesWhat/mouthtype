import CoreGraphics
import Foundation

/// The classic pill's measurements and the maths behind them, with no layers in it. Widths and bar sizes are
/// snapped to whole device pixels (and bar sizes to an even count of them) so the centre-anchored bars land on the
/// pixel grid at 1x and 2x and don't shimmer as they grow.
enum ClassicPillLayout {
    static let height: CGFloat = 28
    /// Side padding of 9 pt either way around the bar group, about the 7 pt above and below a full-height bar.
    static let barSidePadding: CGFloat = 9
    /// The dot-like capsule the pill grows from and shrinks to.
    static let dotWidth: CGFloat = height
    static let barWidth: CGFloat = 2.25
    static let barPitch: CGFloat = 4.25
    static let maxBarHeight: CGFloat = 14.25
    static let controlDiameter: CGFloat = 18
    static let controlInset: CGFloat = 5
    static let controlGap: CGFloat = 10
    static let messagePadding: CGFloat = 16
    static let messageVerticalPadding: CGFloat = 7
    static let messageMinWidth: CGFloat = 64
    static let messageCap: CGFloat = 320
    /// Gap between the headline and the detail under it.
    static let detailGap: CGFloat = 1
    /// A taller pill keeps the corner of the 28 pt one, so the capsule becomes a rounded rectangle.
    static let cornerRadius: CGFloat = height / 2

    /// The same measurements at a pill size. Large is exactly 2x every length, so the 28 pt pill becomes 56 pt. The
    /// bars are the exception to snapping after scaling: they are the Standard bars snapped to the pixel grid and then
    /// doubled, so Large is an exact 2x of Standard at every backing scale.
    struct Metrics: Equatable, Sendable {
        let factor: CGFloat
        init(_ scale: PillScale) { factor = scale.factor }

        static let standard = Metrics(.standard)
        static let large = Metrics(.large)

        var height: CGFloat { ClassicPillLayout.height * factor }
        var barSidePadding: CGFloat { ClassicPillLayout.barSidePadding * factor }
        var dotWidth: CGFloat { height }
        var barWidth: CGFloat { ClassicPillLayout.barWidth * factor }
        var barPitch: CGFloat { ClassicPillLayout.barPitch * factor }
        var maxBarHeight: CGFloat { ClassicPillLayout.maxBarHeight * factor }
        var controlDiameter: CGFloat { ClassicPillLayout.controlDiameter * factor }
        var controlInset: CGFloat { ClassicPillLayout.controlInset * factor }
        var controlGap: CGFloat { ClassicPillLayout.controlGap * factor }
        var messagePadding: CGFloat { ClassicPillLayout.messagePadding * factor }
        var messageVerticalPadding: CGFloat { ClassicPillLayout.messageVerticalPadding * factor }
        var messageMinWidth: CGFloat { ClassicPillLayout.messageMinWidth * factor }
        var messageCap: CGFloat { ClassicPillLayout.messageCap * factor }
        var detailGap: CGFloat { ClassicPillLayout.detailGap * factor }
        var cornerRadius: CGFloat { height / 2 }
    }

    enum Mode: Equatable {
        case hold, locked, processing
        case message(width: CGFloat, height: CGFloat)
    }

    /// Rounds to a whole number of device pixels, returned in points.
    static func snap(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        (value * scale).rounded() / scale
    }

    /// Rounds to an even number of device pixels, so a size centred on the pixel grid has both edges on it.
    static func snapEven(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (value * scale / 2).rounded() / scale
    }

    static func evenCeil(_ value: CGFloat, scale: CGFloat) -> CGFloat {
        2 * (value * scale / 2).rounded(.up) / scale
    }

    /// Bar width and pitch on the pixel grid.
    static func barMetrics(scale: CGFloat, metrics m: Metrics = .standard) -> (width: CGFloat, pitch: CGFloat) {
        (
            max(2 / scale, snapEven(barWidth, scale: scale)) * m.factor,
            max(2 / scale, snapEven(barPitch, scale: scale)) * m.factor
        )
    }

    /// Dot height for silence and the tallest bar, both on the grid.
    static func barHeightRange(scale: CGFloat, metrics m: Metrics = .standard) -> ClosedRange<CGFloat> {
        let width = barMetrics(scale: scale, metrics: m).width
        return width...max(width, snapEven(maxBarHeight, scale: scale) * m.factor)
    }

    /// A smoothed 0...1 fraction as a bar height. The dB mapping and its knee are already in the fraction, so this is
    /// linear: 0 is the resting dot, 1 the tallest bar.
    static func barHeight(fraction: Float, scale: CGFloat, metrics m: Metrics = .standard) -> CGFloat {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        let range = barHeightRange(scale: scale, metrics: m)
        return snapEven(range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(f), scale: scale)
            .clamped(to: range)
    }

    /// A low, slow wave travelling along the bars, as 0...1 fractions for `barHeight`.
    static func processingFractions(time: TimeInterval, count: Int) -> [Float] {
        let t = time.isFinite ? time : 0
        return (0..<count).map { i in
            Float(0.2 + 0.1 * sin(2 * .pi * (t * 0.8 - Double(i) * 0.09)))
        }
    }

    /// Width of the bars alone, first edge to last.
    static func barsSpan(scale: CGFloat, metrics: Metrics = .standard) -> CGFloat {
        let m = barMetrics(scale: scale, metrics: metrics)
        return 9 * m.pitch + m.width
    }

    /// The hold capsule: the bars with the same padding either side.
    static func holdWidth(scale: CGFloat, metrics m: Metrics = .standard) -> CGFloat {
        evenCeil(barsSpan(scale: scale, metrics: m) + 2 * m.barSidePadding, scale: scale)
    }

    static func lockedWidth(scale: CGFloat, metrics m: Metrics = .standard) -> CGFloat {
        evenCeil(2 * (m.controlInset + m.controlDiameter + m.controlGap) + barsSpan(scale: scale, metrics: m), scale: scale)
    }

    /// One line of a laid-out message and where it sits, as the offset of its middle from the block's middle
    /// (positive is down).
    struct MessageLine: Equatable {
        var text: String
        var isDetail: Bool
        var centerOffset: CGFloat
        var height: CGFloat
    }

    struct MessageBlock: Equatable {
        var width: CGFloat
        var height: CGFloat
        var lines: [MessageLine]
        /// How far the lines run past the room the capsule has for them, 0 when they all fit. A pill with room to grow
        /// never has any; a capped one scrolls its text by this much.
        var overflow: CGFloat = 0
    }

    /// Breaks a message at its logical point: the headline on its own line or lines, the detail under it. A part wraps
    /// onto further lines only where it is wider than the cap, at a word boundary, and a single word wider than the
    /// cap breaks between characters. Nothing is cut off. `measure` gives a string's width in the part's real font.
    static func messageBlock(
        headline: String, detail: String?, headlineLineHeight: CGFloat, detailLineHeight: CGFloat,
        scale: CGFloat, metrics m: Metrics = .standard, measure: (String, _ isDetail: Bool) -> CGFloat
    ) -> MessageBlock {
        let available = m.messageCap - 2 * m.messagePadding
        let head = wrap(headline, width: available) { measure($0, false) }
        let tail = (detail?.isEmpty == false) ? wrap(detail ?? "", width: available) { measure($0, true) } : []
        let widest = (head.map { measure($0, false) } + tail.map { measure($0, true) }).max() ?? 0
        let width = evenCeil(min(m.messageCap, max(m.messageMinWidth, ceil(widest) + 2 * m.messagePadding)), scale: scale)

        let stack = head.count * Int(headlineLineHeight.rounded()) + tail.count * Int(detailLineHeight.rounded())
        let gap = tail.isEmpty ? 0 : m.detailGap
        let block = CGFloat(stack) + gap
        let height = head.count + tail.count == 1
            ? m.height
            : max(m.height, evenCeil(block + 2 * m.messageVerticalPadding, scale: scale))
        var lines: [MessageLine] = []
        var y = -block / 2
        for text in head {
            lines.append(MessageLine(text: text, isDetail: false, centerOffset: y + headlineLineHeight / 2, height: headlineLineHeight))
            y += headlineLineHeight
        }
        y += gap
        for text in tail {
            lines.append(MessageLine(text: text, isDetail: true, centerOffset: y + detailLineHeight / 2, height: detailLineHeight))
            y += detailLineHeight
        }
        return MessageBlock(width: width, height: height, lines: lines)
    }

    /// Greedy word wrap to `width`; an over-wide word is split between characters.
    static func wrap(_ text: String, width: CGFloat, measure: (String) -> CGFloat) -> [String] {
        var lines: [String] = []
        var current = ""
        func flush() {
            if !current.isEmpty { lines.append(current) }
            current = ""
        }
        for word in text.split(separator: " ", omittingEmptySubsequences: true).map(String.init) {
            let joined = current.isEmpty ? word : current + " " + word
            if measure(joined) <= width {
                current = joined
                continue
            }
            flush()
            if measure(word) <= width {
                current = word
                continue
            }
            for character in word {
                let next = current + String(character)
                if measure(next) > width, !current.isEmpty {
                    flush()
                    current = String(character)
                } else {
                    current = next
                }
            }
        }
        flush()
        return lines.isEmpty ? [""] : lines
    }

    static func capsuleWidth(_ mode: Mode, scale: CGFloat, metrics m: Metrics = .standard) -> CGFloat {
        switch mode {
        case .hold, .processing: holdWidth(scale: scale, metrics: m)
        case .locked: lockedWidth(scale: scale, metrics: m)
        case .message(let width, _): width
        }
    }

    static func capsuleHeight(_ mode: Mode, metrics m: Metrics = .standard) -> CGFloat {
        if case .message(_, let height) = mode { return height }
        return m.height
    }

    /// The capsule inside a view of `bounds`: centred across, `bottomMargin` up from the bottom.
    static func capsuleFrame(
        width: CGFloat, height: CGFloat = ClassicPillLayout.height, bounds: CGSize, bottomMargin: CGFloat, scale: CGFloat
    ) -> CGRect {
        CGRect(x: snap((bounds.width - width) / 2, scale: scale), y: bottomMargin, width: width, height: height)
    }

    /// One frame per bar, centred on the capsule's middle.
    static func barFrames(capsule: CGRect, heights: [CGFloat], scale: CGFloat, metrics: Metrics = .standard) -> [CGRect] {
        let m = barMetrics(scale: scale, metrics: metrics)
        let range = barHeightRange(scale: scale, metrics: metrics)
        return heights.enumerated().map { i, raw in
            let h = raw.clamped(to: range)
            let centre = capsule.midX + (CGFloat(i) - CGFloat(heights.count - 1) / 2) * m.pitch
            return CGRect(x: centre - m.width / 2, y: capsule.midY - h / 2, width: m.width, height: h)
        }
    }

    /// The cancel disc at the left end and the stop disc at the right.
    static func controlFrames(capsule: CGRect, metrics m: Metrics = .standard) -> [PillControl: CGRect] {
        let d = m.controlDiameter
        let y = capsule.midY - d / 2
        return [
            .cancel: CGRect(x: capsule.minX + m.controlInset, y: y, width: d, height: d),
            .stop: CGRect(x: capsule.maxX - m.controlInset - d, y: y, width: d, height: d),
        ]
    }
}

extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat { Swift.min(range.upperBound, Swift.max(range.lowerBound, self)) }
}
