import Foundation
import MouthtypeCore

/// Display strings for the Stats and Records pages. Nothing here shortens text.
enum StatsFormat {
    static func number(_ n: Int) -> String { n.formatted(.number) }

    static func wpm(_ value: Double?) -> String { value.map { "\(Int($0.rounded())) WPM" } ?? "No data yet" }

    /// "2 h 5 min", "12 min", "Under a minute".
    static func duration(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 1 { return minutes > 0 ? "Under a minute" : "None yet" }
        let (h, m) = total.quotientAndRemainder(dividingBy: 60)
        if h == 0 { return "\(m) min" }
        return m == 0 ? "\(h) h" : "\(h) h \(m) min"
    }

    static func speaking(ms: Int?) -> String? {
        guard let ms, ms > 0 else { return nil }
        let seconds = Int((Double(ms) / 1000).rounded())
        return seconds >= 60 ? "\(seconds / 60) min \(seconds % 60) s" : "\(seconds) s"
    }

    static func days(_ n: Int) -> String { n == 1 ? "1 day" : "\(n) days" }

    private static let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]

    /// "2026-10-03" as "Oct 3, 2026". A malformed day is shown as stored.
    static func date(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2]), \(parts[0])"
    }

    /// "Oct 3".
    static func shortDay(_ day: String) -> String {
        let parts = day.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3, (1...12).contains(parts[1]) else { return day }
        return "\(months[parts[1] - 1]) \(parts[2])"
    }

    // MARK: Redesigned Stats page

    /// "2:04 PM" from seconds since local midnight.
    static func clock(seconds: Int) -> String {
        let hour = (seconds / 3_600) % 24
        let minute = (seconds % 3_600) / 60
        return String(format: "%d:%02d %@", hour % 12 == 0 ? 12 : hour % 12, minute, hour < 12 ? "AM" : "PM")
    }

    /// "2 PM", "12 AM".
    static func hourName(_ hour: Int) -> String {
        let h = ((hour % 24) + 24) % 24
        return "\(h % 12 == 0 ? 12 : h % 12) \(h < 12 ? "AM" : "PM")"
    }

    /// "88 hours you didn't have to type." Under an hour it counts minutes; with nothing saved it says so.
    static func savedHeadline(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        if total < 1 { return "Nothing saved yet." }
        if total < 60 { return "\(total) \(total == 1 ? "minute" : "minutes") you didn't have to type." }
        let hours = Int((minutes / 60).rounded())
        return "\(number(hours)) \(hours == 1 ? "hour" : "hours") you didn't have to type."
    }

    /// "22 h 10 min" from a minute count, for the mono readouts. "0 min" when empty.
    static func talking(minutes: Double) -> String {
        let total = Int(minutes.rounded())
        let (h, m) = total.quotientAndRemainder(dividingBy: 60)
        return h == 0 ? "\(m) min" : "\(h) h \(m) min"
    }

    /// "12 min 48 s" from milliseconds. "0 s" when empty.
    static func talking(ms: Int) -> String { speaking(ms: ms) ?? "0 s" }

    /// A record's date: "Oct 9" this year, "Oct 9, 2025" otherwise.
    static func recordDate(_ day: String, today: String) -> String {
        day.prefix(4) == today.prefix(4) ? shortDay(day) : date(day)
    }

    /// The meter segment holding `value`, 0-based, over `segments` segments spanning 0 to `top`. Nil for no value.
    static func meterSegment(_ value: Double?, segments: Int = 25, top: Double = 250) -> Int? {
        guard let value, value > 0 else { return nil }
        let width = top / Double(segments)
        return min(segments - 1, max(0, Int((value / width).rounded(.up)) - 1))
    }

    /// The typist comparison for the speed card: "4× a typist." style, or nothing when slower.
    static func typistRatio(wpm: Double?, typingWPM: Double) -> String? {
        guard let wpm, typingWPM > 0, wpm / typingWPM >= 1.5 else { return nil }
        let ratio = (wpm / typingWPM * 10).rounded() / 10
        let text = ratio == ratio.rounded() ? String(Int(ratio)) : String(format: "%.1f", ratio)
        return "\(text)× a typist."
    }
}
