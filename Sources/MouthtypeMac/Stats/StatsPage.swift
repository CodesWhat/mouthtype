import SwiftUI
import MouthtypeCore

/// Usage numbers from the local dictation log, in the Settings grouped-form look. Standalone: the Home window hosts it
/// later. The caller passes in a `StatsReport` and the last couple of weeks of `DailyWords`.
struct StatsPage: View {
    let report: StatsReport
    let daily: [DailyWords]

    var body: some View {
        SettingsForm {
            SettingsGroup(eyebrow: "WORDS") {
                stat("Today", StatsFormat.number(report.wordsToday))
                stat("This week", StatsFormat.number(report.wordsThisWeek), detail: "The last seven days, including today.")
                stat("All time", StatsFormat.number(report.wordsAllTime), detail: "Across \(StatsFormat.number(report.dictationCount)) dictations.")
            }
            if !daily.isEmpty {
                SettingsGroup(eyebrow: "DAILY WORDS") { DailyBars(days: daily).padding(.vertical, 8) }
            }
            SettingsGroup(
                eyebrow: "SPEED",
                footer: "Words per minute of speaking, from dictations of at least 5 words and 3 seconds. The average is total words over total speaking time."
            ) {
                stat("Average speed", StatsFormat.wpm(report.averageWPM))
                stat("Best speed", StatsFormat.wpm(report.bestWPM))
            }
            SettingsGroup(eyebrow: "STREAK") {
                stat("Current streak", StatsFormat.days(report.currentStreakDays), detail: "Days in a row with at least one dictation.")
                stat("Longest streak", StatsFormat.days(report.longestStreakDays))
            }
            SettingsGroup(eyebrow: "HIGHS") {
                stat("Biggest day", report.biggestDay.map { "\(StatsFormat.number($0.words)) words" } ?? "None yet",
                     detail: report.biggestDay.map { StatsFormat.date($0.day) })
                stat("Longest dictation", report.longestDictation.map { "\(StatsFormat.number($0.words)) words" } ?? "None yet",
                     detail: report.longestDictation.map { longestDetail($0) })
            }
            SettingsGroup(
                eyebrow: "TIME SAVED",
                footer: "Compared with typing the same words at \(Int(report.typingWPM)) WPM. Everything here is worked out on this Mac from your own log."
            ) {
                stat("Time saved", StatsFormat.duration(minutes: report.minutesSaved))
            }
        }
    }

    private func longestDetail(_ d: LongestDictation) -> String {
        [StatsFormat.date(d.day), StatsFormat.speaking(ms: d.durationMs)].compactMap { $0 }.joined(separator: ", ")
    }

    private func stat(_ title: String, _ value: String, detail: String? = nil) -> some View {
        SettingsRow(title: title, detail: detail) {
            Text(value).font(SettingsFont.sans(SettingsFont.body)).monospacedDigit().fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Bars for each day, scaled to the busiest day, with the first and last day labelled.
struct DailyBars: View {
    let days: [DailyWords]
    private let height: CGFloat = 70

    var body: some View {
        let peak = max(days.map(\.words).max() ?? 0, 1)
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .bottom, spacing: 3) {
                ForEach(days.indices, id: \.self) { i in
                    RoundedRectangle(cornerRadius: 2)
                        .fill(days[i].words > 0 ? SettingsTheme.control : Color.primary.opacity(0.1))
                        .frame(height: days[i].words > 0 ? max(3, height * CGFloat(days[i].words) / CGFloat(peak)) : 3)
                        .frame(maxWidth: .infinity)
                        .accessibilityElement()
                        .accessibilityLabel("\(StatsFormat.date(days[i].day)): \(days[i].words) words")
                }
            }.frame(height: height, alignment: .bottom)
            HStack {
                Text(StatsFormat.shortDay(days[0].day))
                Spacer()
                Text("Busiest: \(StatsFormat.number(peak)) words")
                Spacer()
                Text(StatsFormat.shortDay(days[days.count - 1].day))
            }.font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(.secondary)
        }
    }
}
