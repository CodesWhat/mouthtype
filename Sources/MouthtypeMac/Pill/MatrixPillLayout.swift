import CoreGraphics
import Foundation

/// The Matrix and Minimal pills' measurements and the maths behind them, with no layers in it. Both are a 30 pt
/// squircle with the same slots; Matrix fills the meter slot with a 13 x 7 dot grid and Minimal with ten plain bars.
/// Large is exactly 2x every length, as for the Classic pill.
enum MatrixPillLayout {
    static let height: CGFloat = 30
    static let padLeft: CGFloat = 12
    static let padRight: CGFloat = 12
    /// The right pad once the controls take the end of a locked pill.
    static let lockedPadRight: CGFloat = 5
    static let indicatorSlot: CGFloat = 10
    static let gap: CGFloat = 7
    static let recSlot: CGFloat = 22
    static let clockSlot: CGFloat = 26

    static let columns = 13
    static let rows = 7
    static let dotSize: CGFloat = 2
    static let dotPitch: CGFloat = 3
    static let barCount = BarModel.barCount
    static let barWidth: CGFloat = 2
    static let barPitch: CGFloat = 4
    /// The meter slot is 38 pt wide for either readout: 12 x 3 + 2 for the dots, 9 x 4 + 2 for the bars.
    static let meterWidth: CGFloat = 38

    static let controlSize: CGFloat = 20
    static let controlGap: CGFloat = 3
    /// The superellipse corner: exponent 4, reaching 0.34 x 1.32 of the height into each edge, 13.5 pt on a 30 pt pill.
    static let cornerFactor: CGFloat = 0.34 * 1.32
    static let cornerSegments = 22

    /// A message wraps at this width, then the pill grows taller.
    static let wrapWidth: CGFloat = 150
    static let messageVerticalPadding: CGFloat = 7
    /// The light Matrix readout sits in a window inset this far from the body.
    static let windowInset: CGFloat = 3
    /// Half-rows: a column lights 2n - 1 rows around the middle, n in 1...4, and n 0 keeps only the middle dot.
    static var maxHalfRows: Int { (rows + 1) / 2 }
    static let idleAlpha: CGFloat = 0.45

    struct Metrics: Equatable, Sendable {
        let factor: CGFloat
        init(_ scale: PillScale) { factor = scale.factor }

        static let standard = Metrics(.standard)
        static let large = Metrics(.large)

        var height: CGFloat { MatrixPillLayout.height * factor }
        var padLeft: CGFloat { MatrixPillLayout.padLeft * factor }
        var padRight: CGFloat { MatrixPillLayout.padRight * factor }
        var lockedPadRight: CGFloat { MatrixPillLayout.lockedPadRight * factor }
        var indicatorSlot: CGFloat { MatrixPillLayout.indicatorSlot * factor }
        var gap: CGFloat { MatrixPillLayout.gap * factor }
        var recSlot: CGFloat { MatrixPillLayout.recSlot * factor }
        var clockSlot: CGFloat { MatrixPillLayout.clockSlot * factor }
        var dotSize: CGFloat { MatrixPillLayout.dotSize * factor }
        var dotPitch: CGFloat { MatrixPillLayout.dotPitch * factor }
        var barWidth: CGFloat { MatrixPillLayout.barWidth * factor }
        var barPitch: CGFloat { MatrixPillLayout.barPitch * factor }
        var meterWidth: CGFloat { MatrixPillLayout.meterWidth * factor }
        var controlSize: CGFloat { MatrixPillLayout.controlSize * factor }
        var controlGap: CGFloat { MatrixPillLayout.controlGap * factor }
        var wrapWidth: CGFloat { MatrixPillLayout.wrapWidth * factor }
        var messageVerticalPadding: CGFloat { MatrixPillLayout.messageVerticalPadding * factor }
        var windowInset: CGFloat { MatrixPillLayout.windowInset * factor }

        /// Distances from the capsule's left edge.
        var indicatorCentre: CGFloat { padLeft + indicatorSlot / 2 }
        var meterX: CGFloat { padLeft + indicatorSlot + gap }
        var labelX: CGFloat { meterX + meterWidth + gap }
        var textX: CGFloat { padLeft + indicatorSlot + gap }
        var heldWidth: CGFloat { labelX + recSlot + padRight }
        var lockedWidth: CGFloat {
            labelX + clockSlot + gap + 2 * controlSize + controlGap + lockedPadRight
        }
    }

    enum Mode: Equatable {
        case hold, locked, processing
        case message(width: CGFloat, height: CGFloat)
        /// The readout row of a card folded into the pill: the lamp, the idle meter and one short label or clock.
        case readout(CardReadout)
    }

    static func capsuleWidth(_ mode: Mode, metrics m: Metrics = .standard) -> CGFloat {
        switch mode {
        case .hold, .processing, .readout: m.heldWidth
        case .locked: m.lockedWidth
        case .message(let width, _): width
        }
    }

    static func capsuleHeight(_ mode: Mode, metrics m: Metrics = .standard) -> CGFloat {
        if case .message(_, let height) = mode { return height }
        return m.height
    }

    /// The capsule inside a view of `bounds`: centred across, `bottomMargin` up from the bottom.
    static func capsuleFrame(
        width: CGFloat, height: CGFloat, bounds: CGSize, bottomMargin: CGFloat, scale: CGFloat
    ) -> CGRect {
        CGRect(x: ClassicPillLayout.snap((bounds.width - width) / 2, scale: scale), y: bottomMargin, width: width, height: height)
    }

    /// The squircle's corner reference for a card of corner `radius`: the path's corner is `cornerFactor` of it.
    static func cornerReference(radius: CGFloat) -> CGFloat { radius / cornerFactor }

    /// The cancel and finish squircles at the right end, 3 pt apart and 5 pt from the edge.
    static func controlFrames(capsule: CGRect, metrics m: Metrics = .standard) -> [PillControl: CGRect] {
        let d = m.controlSize
        let y = capsule.midY - d / 2
        let finish = CGRect(x: capsule.maxX - m.lockedPadRight - d, y: y, width: d, height: d)
        let cancel = CGRect(x: finish.minX - m.controlGap - d, y: y, width: d, height: d)
        return [.cancel: cancel, .stop: finish]
    }

    /// The light Matrix readout window: inset from the body, ending after the clock when locked.
    static func windowFrame(capsule: CGRect, locked: Bool, metrics m: Metrics = .standard) -> CGRect {
        let inset = m.windowInset
        let right = locked ? capsule.minX + m.labelX + m.clockSlot + 4 * m.factor : capsule.maxX - inset
        return CGRect(x: capsule.minX + inset, y: capsule.minY + inset, width: right - (capsule.minX + inset), height: capsule.height - 2 * inset)
    }

    // MARK: Level to readout

    /// Half-rows lit for a 0...1 level: 0 is silence (the idle dot only), 1...4 light 1, 3, 5 or 7 rows around the middle.
    static func halfRows(fraction: Float) -> Int {
        let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
        guard f >= 0.015 else { return 0 }
        return max(1, Int((f * Float(maxHalfRows)).rounded()))
    }

    /// The rows lit in a column of `halfRows`, row 0 at the bottom; empty for silence.
    static func litRows(halfRows n: Int) -> ClosedRange<Int>? {
        guard n > 0 else { return nil }
        let middle = (rows - 1) / 2
        let reach = min(n, maxHalfRows) - 1
        return (middle - reach)...(middle + reach)
    }

    /// Ten smoothed bar levels spread over `count` columns by linear interpolation, end to end.
    static func columnFractions(from fractions: [Float], count: Int) -> [Float] {
        guard count > 0 else { return [] }
        guard fractions.count > 1 else { return [Float](repeating: fractions.first ?? 0, count: count) }
        return (0..<count).map { i in
            let position = Float(i) * Float(fractions.count - 1) / Float(max(1, count - 1))
            let low = min(fractions.count - 1, Int(position))
            let high = min(fractions.count - 1, low + 1)
            let t = position - Float(low)
            return fractions[low] + (fractions[high] - fractions[low]) * t
        }
    }

    /// Half-rows per dot column from the pill's ten bar levels.
    static func dotHalfRows(fractions: [Float]) -> [Int] {
        columnFractions(from: fractions, count: columns).map { halfRows(fraction: $0) }
    }

    /// Half-rows per bar, one for each of the ten bars.
    static func barHalfRows(fractions: [Float]) -> [Int] {
        (0..<barCount).map { halfRows(fraction: $0 < fractions.count ? fractions[$0] : 0) }
    }

    /// Height of a Minimal bar in points: 2, 8, 14 or 20 for 1...4 half-rows, a 2 pt dot for silence.
    static func barHeight(halfRows n: Int, metrics m: Metrics = .standard) -> CGFloat {
        n <= 0 ? m.barWidth : CGFloat((2 * min(n, maxHalfRows) - 1) * 3 - 1) * m.factor
    }

    /// The dot at `column`, `row` (0 at the bottom) with the grid's left edge at `x` and its middle at `midY`.
    static func dotFrame(column: Int, row: Int, x: CGFloat, midY: CGFloat, metrics m: Metrics = .standard) -> CGRect {
        let bottom = midY - ((CGFloat(rows - 1) * dotPitch + dotSize) / 2) * m.factor
        return CGRect(x: x + CGFloat(column) * m.dotPitch, y: bottom + CGFloat(row) * m.dotPitch, width: m.dotSize, height: m.dotSize)
    }

    /// The bar at `index`, centred on `midY`.
    static func barFrame(index: Int, halfRows n: Int, x: CGFloat, midY: CGFloat, metrics m: Metrics = .standard) -> CGRect {
        let h = barHeight(halfRows: n, metrics: m)
        return CGRect(x: x + CGFloat(index) * m.barPitch, y: midY - h / 2, width: m.barWidth, height: h)
    }

    /// The processing scanner: a bright head bouncing along the columns over 900 ms with a soft falloff.
    static let scannerPeriod: TimeInterval = 0.9

    static func processingFractions(time: TimeInterval, count: Int) -> [Float] {
        let t = time.isFinite ? time : 0
        let head = (sin(t / scannerPeriod * 2 * .pi - .pi / 2) * 0.5 + 0.5) * Double(max(0, count - 1))
        return (0..<count).map { i in
            let v = min(1, max(0, 1 - abs(Double(i) - head) / 2.6)) * 0.95
            return v > 0.05 ? Float(v) : 0
        }
    }

    /// The three dots in the label slot step every 220 ms: 0...3 of them lit.
    static func processingDotsLit(time: TimeInterval) -> Int {
        Int(max(0, time.isFinite ? time : 0) / 0.22) % 4
    }

    // MARK: Message

    /// Breaks a message like the Classic pill does, but at 150 pt, with the text starting after the indicator. The
    /// pill is as wide as the text needs (at least the held width) and grows taller for wrapped lines, up to
    /// `maxHeight`. Past that the pill stays that tall and `overflow` says how far the text has to scroll.
    static func messageBlock(
        headline: String, detail: String?, headlineLineHeight: CGFloat, detailLineHeight: CGFloat,
        scale: CGFloat, metrics m: Metrics = .standard, maxHeight: CGFloat = .greatestFiniteMagnitude,
        measure: (String, _ isDetail: Bool) -> CGFloat
    ) -> ClassicPillLayout.MessageBlock {
        let head = ClassicPillLayout.wrap(headline, width: m.wrapWidth) { measure($0, false) }
        let tail = (detail?.isEmpty == false) ? ClassicPillLayout.wrap(detail ?? "", width: m.wrapWidth) { measure($0, true) } : []
        let widest = (head.map { measure($0, false) } + tail.map { measure($0, true) }).max() ?? 0
        let width = ClassicPillLayout.evenCeil(max(m.heldWidth, m.textX + ceil(widest) + m.padRight), scale: scale)

        let stack = head.count * Int(headlineLineHeight.rounded()) + tail.count * Int(detailLineHeight.rounded())
        let gap = tail.isEmpty ? 0 : ClassicPillLayout.detailGap * m.factor
        let block = CGFloat(stack) + gap
        let wanted = head.count + tail.count == 1
            ? m.height
            : max(m.height, ClassicPillLayout.evenCeil(block + 2 * m.messageVerticalPadding, scale: scale))
        let cap = maxHeight.isFinite && maxHeight < .greatestFiniteMagnitude
            ? max(m.height, 2 * (maxHeight * scale / 2).rounded(.down) / scale)
            : wanted
        let height = min(wanted, cap)
        let overflow = max(0, block - (height - 2 * m.messageVerticalPadding))
        var lines: [ClassicPillLayout.MessageLine] = []
        var y = -block / 2
        for text in head {
            lines.append(.init(text: text, isDetail: false, centerOffset: y + headlineLineHeight / 2, height: headlineLineHeight))
            y += headlineLineHeight
        }
        y += gap
        for text in tail {
            lines.append(.init(text: text, isDetail: true, centerOffset: y + detailLineHeight / 2, height: detailLineHeight))
            y += detailLineHeight
        }
        return ClassicPillLayout.MessageBlock(width: width, height: height, lines: lines, overflow: overflow)
    }

    // MARK: Squircle

    /// A rect with superellipse corners (|x|^4 + |y|^4 = 1) joined by straight edges. `reference` sizes the corner, so
    /// a taller pill keeps the corner of the 30 pt one. The path always has the same number of points, which lets a
    /// width change animate as a path interpolation.
    static func squirclePath(_ rect: CGRect, reference: CGFloat) -> CGPath {
        let a = min(cornerFactor * reference, rect.height / 2, rect.width / 2)
        let path = CGMutablePath()
        let corners: [(cx: CGFloat, cy: CGFloat, start: CGFloat)] = [
            (rect.maxX - a, rect.maxY - a, 0), (rect.minX + a, rect.maxY - a, 90),
            (rect.minX + a, rect.minY + a, 180), (rect.maxX - a, rect.minY + a, 270),
        ]
        var first = true
        for corner in corners {
            for i in 0...cornerSegments {
                let t = (corner.start + 90 * CGFloat(i) / CGFloat(cornerSegments)) * .pi / 180
                let c = cos(t), s = sin(t)
                let point = CGPoint(
                    x: corner.cx + a * (c < 0 ? -1 : 1) * pow(abs(c), 0.5),
                    y: corner.cy + a * (s < 0 ? -1 : 1) * pow(abs(s), 0.5)
                )
                if first { path.move(to: point); first = false } else { path.addLine(to: point) }
            }
        }
        path.closeSubpath()
        return path
    }
}
