import Foundation

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
}
