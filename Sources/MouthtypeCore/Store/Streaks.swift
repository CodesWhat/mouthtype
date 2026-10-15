import Foundation

enum Streaks {
    /// `days` are `YYYY-MM-DD`, ascending, each with at least one word. The current streak is the run ending at the
    /// last day, and only counts if that day is `today` or the day before.
    static func compute(days: [String], today: String) -> (current: Int, longest: Int) {
        let numbers = days.compactMap(dayNumber).reduce(into: [Int]()) { out, n in
            if out.last != n { out.append(n) }
        }
        guard let last = numbers.last, let todayNumber = dayNumber(today) else { return (0, 0) }

        var longest = 1
        var run = 1
        for i in numbers.indices.dropFirst() {
            run = numbers[i] == numbers[i - 1] + 1 ? run + 1 : 1
            longest = max(longest, run)
        }
        // `run` now holds the run that ends at the last day.
        let current = last >= todayNumber - 1 && last <= todayNumber ? run : 0
        return (current, longest)
    }

    /// Days since 1970-01-01 for a `YYYY-MM-DD` string (proleptic Gregorian), nil if malformed.
    static func dayNumber(_ day: String) -> Int? {
        let parts = day.split(separator: "-")
        guard parts.count == 3, let y = Int(parts[0]), let m = Int(parts[1]), let d = Int(parts[2]),
              (1...12).contains(m), (1...31).contains(d) else { return nil }
        let year = m <= 2 ? y - 1 : y
        let era = (year >= 0 ? year : year - 399) / 400
        let yoe = year - era * 400
        let doy = (153 * (m > 2 ? m - 3 : m + 9) + 2) / 5 + d - 1
        let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy
        return era * 146_097 + doe - 719_468
    }

    static func localDay(for date: Date, in timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 1970, c.month ?? 1, c.day ?? 1)
    }
}
