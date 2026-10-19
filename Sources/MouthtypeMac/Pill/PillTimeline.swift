import Foundation

/// The small clocked pieces of the pill, pure so they can be tested without a view.
enum PillTimeline {
    /// `M:SS`, held at 9:59 because the readout has room for one minute digit.
    static func timerText(seconds: Int) -> String {
        let s = min(max(0, seconds), 9 * 60 + 59)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    /// The REC lamp: steady while a hold recording runs, about 1 Hz while locked hands-free.
    static func ledOn(elapsed: TimeInterval, locked: Bool) -> Bool {
        guard locked else { return true }
        return Int(max(0, elapsed) * 2) % 2 == 0
    }
}

/// How a message sits in the VFD window: centred when it fits, otherwise shown from its start, held, scrolled once
/// until its end is flush with the window edge, and held again. Offsets are whole pixels.
enum Marquee {
    enum Layout: Equatable {
        case centered(offset: Int)
        case scrolling(distance: Int)
    }

    static let hold: TimeInterval = 0.6
    static let pixelsPerSecond: Double = 30

    static func layout(textWidth: Int, windowWidth: Int) -> Layout {
        textWidth <= windowWidth ? .centered(offset: (windowWidth - textWidth) / 2) : .scrolling(distance: textWidth - windowWidth)
    }

    /// Under Reduce Motion the text doesn't travel: it is held, then shown at its end.
    static func duration(distance: Int, reduceMotion: Bool = false) -> TimeInterval {
        reduceMotion ? 2 * hold : hold + Double(distance) / pixelsPerSecond + hold
    }

    /// Horizontal offset of the text at `time`, 0 at the start down to `-distance` at the end.
    static func offset(distance: Int, at time: TimeInterval, reduceMotion: Bool = false) -> Int {
        if reduceMotion { return time < hold ? 0 : -distance }
        let travelled = Int(max(0, time - hold) * pixelsPerSecond)
        return -min(distance, travelled)
    }
}
