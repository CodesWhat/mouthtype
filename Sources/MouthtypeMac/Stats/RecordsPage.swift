import SwiftUI
import MouthtypeCore

/// The local arcade board: your own bests and the day each was set. No accounts and no online leaderboard.
/// Standalone: the Home window hosts it later.
struct RecordsPage: View {
    let records: ArcadeRecords

    var body: some View {
        SettingsForm {
            SettingsGroup(
                eyebrow: "PERSONAL BESTS",
                footer: "Kept on this Mac and rebuilt from your dictation log, so they always match what you actually dictated."
            ) {
                row("Fastest speaking", records.wpm.map { StatsFormat.wpm($0.value) }, setOn: records.wpm?.setOn)
                row("Biggest day", records.biggestDay.map { "\(StatsFormat.number($0.value)) words" }, setOn: records.biggestDay?.setOn)
                row("Longest streak", records.longestStreak.map { StatsFormat.days($0.value) }, setOn: records.longestStreak?.setOn)
                row("Longest dictation", records.longestDictation.map { "\(StatsFormat.number($0.value.words)) words" },
                    setOn: records.longestDictation?.setOn, extra: StatsFormat.speaking(ms: records.longestDictation?.value.durationMs))
            }
        }
    }

    private func row(_ title: String, _ value: String?, setOn: String?, extra: String? = nil) -> some View {
        let detail = setOn.map { "Set \(StatsFormat.date($0))" + (extra.map { ", \($0)" } ?? "") } ?? "Not set yet"
        return SettingsRow(title: title, detail: detail) {
            Text(value ?? "None yet").font(SettingsFont.sans(SettingsFont.body)).monospacedDigit()
                .foregroundStyle(value == nil ? .secondary : .primary).fixedSize(horizontal: false, vertical: true)
        }
    }
}
