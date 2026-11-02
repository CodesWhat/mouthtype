import CoreGraphics
import MouthtypeCore

/// The Hi-Fi trophy toast: the delivery card's brushed-metal window with a title plate, status LED and close button, and the
/// trophy name and line in the VFD in the pixel faces, with the same trophy cup beside them. Composed at one art pixel per
/// pixel with the card's own layout and art; the view magnifies it at a whole-number scale.
@MainActor
enum HiFiAchievementToast {
    struct Face {
        var image: CGImage
        var frames: HiFiCardLayout.Frames
    }

    /// Room for the cup beside the text: its width and a gap.
    static let cupColumn = TrophyArt.width + 4

    /// The window at 1x with the countdown bar at `fraction`, or nil when the pixel faces cannot draw the words as written or the
    /// words need more lines than the VFD holds. The caller then draws the Classic toast: text is never cut short.
    static func compose(
        toast: AchievementToast, assets: HiFiCardAssets, readout: PillReadoutColour, fraction: Double
    ) -> Face? {
        let m = assets.metrics, m3 = assets.font3.metrics, m5 = assets.font5.metrics
        guard HiFiCardText.canDraw(toast.kicker, metrics: m3), HiFiCardText.canDraw(toast.title, metrics: m5),
            HiFiCardText.canDraw(toast.body, metrics: m5)
        else { return nil }
        let title = HiFiCardText.display(toast.kicker, metrics: m3)
        guard m3.width(of: title) <= HiFiCardLayout.titleMaxWidth(m) else { return nil }
        let lines = HiFiCardText.wrap(
            [
                (HiFiCardText.display(toast.title, metrics: m5), .emphasis), ("\n", .normal),
                (HiFiCardText.display(toast.body, metrics: m5), .normal),
            ], metrics: m5, maxWidth: HiFiCardLayout.textMaxWidth(m) - cupColumn)
        guard lines.count <= m.maxLines else { return nil }
        // Enough lines that the VFD is at least as tall as the cup.
        var rows = lines.count
        while rows * m5.cellHeight + (rows - 1) * m.vfd.lineGap < TrophyArt.height, rows < m.maxLines { rows += 1 }
        let frames = HiFiCardLayout.make(
            .init(titleWidth: m3.width(of: title), lineCount: rows, lineHeight: m5.cellHeight, hasBar: true, buttonLabelWidths: []), m)
        guard let canvas = HiFiCanvas(width: frames.width, height: frames.height), let frameSlices = assets.slices(of: "frame"),
            let vfd = frames.vfd, let vfdSlices = assets.slices(of: "vfd")
        else { return nil }
        let c = assets.spec.colors
        let p = readout.palette(base: assets.pill.layout.colors)
        canvas.nineSlice(assets.frame, slices: frameSlices, in: .init(x: 0, y: 0, w: frames.width, h: frames.height))
        canvas.fill(frames.plate, PillLayout.color(hex: c.metal))
        canvas.fill(frames.plate.x, frames.plate.y, frames.plate.w, 1, HiFiCanvas.mix(c.metal, c.metalHi, 0.4))
        if let led = assets.pill.sprites["led_on"], let tinted = HiFiCanvas.tinted(led, PillLayout.color(hex: p.normal)) {
            canvas.draw(tinted, x: frames.led.x, y: frames.led.y)
            canvas.fill(frames.led.x + 1, frames.led.y + 1, 1, 1, HiFiCanvas.mix(p.normal, "#ffffff", 0.55))
        }
        if let ear = assets.font5.image(for: String(HiFiCardText.ear), color: PillLayout.color(hex: c.engraveHi)) {
            canvas.draw(ear, x: frames.ear.x, y: frames.ear.y)
        }
        if let text = assets.font3.image(for: title, color: PillLayout.color(hex: c.engraveHi)) {
            canvas.draw(text, x: Int(frames.titleOrigin.x), y: Int(frames.titleOrigin.y))
        }
        canvas.draw(assets.closeUp, x: frames.close.x, y: frames.close.y)
        canvas.nineSlice(assets.vfd, slices: vfdSlices, in: vfd)

        let step = m5.cellHeight + m.vfd.lineGap
        let textX = Int(frames.textOrigin.x), textY = Int(frames.textOrigin.y)
        let blockHeight = rows * m5.cellHeight + (rows - 1) * m.vfd.lineGap
        if let cup = cupImage(toast) {
            canvas.draw(cup, x: textX, y: textY + max(0, (blockHeight - TrophyArt.height) / 2))
        }
        for (row, line) in lines.enumerated() {
            var drawn = ""
            for run in line {
                let hex = run.style == .emphasis ? p.hot : p.text
                let x = textX + cupColumn + (drawn.isEmpty ? 0 : assets.font5.width(of: drawn) + m5.gap)
                if let image = assets.font5.image(for: run.text, color: PillLayout.color(hex: hex)) {
                    canvas.draw(image, x: x, y: textY + row * step)
                }
                drawn += run.text
            }
        }
        if let bar = frames.bar {
            let count = (bar.w + m.vfd.barSegGap) / (m.vfd.barSegW + m.vfd.barSegGap)
            let lit = HiFiCardLayout.litSegments(fraction: CGFloat(fraction), count: count)
            let on = PillLayout.color(hex: p.normal), off = HiFiCanvas.mix(p.normal, c.vfdBg, 0.85)
            for index in 0..<count {
                canvas.fill(bar.x + index * (m.vfd.barSegW + m.vfd.barSegGap), bar.y, m.vfd.barSegW, bar.h, index < lit ? on : off)
            }
        }
        guard let image = canvas.makeImage() else { return nil }
        return Face(image: image, frames: frames)
    }

    /// The cup in its tier colour, on the dark VFD's palette.
    private static func cupImage(_ toast: AchievementToast) -> CGImage? {
        TrophyArt.canvas(spriteID: toast.spriteID ?? "", face: .earned(toast.tier), dark: true).image
    }
}
