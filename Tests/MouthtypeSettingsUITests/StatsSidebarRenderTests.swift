import AppKit
import Testing
import SwiftUI
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct StatsSidebarRenderTests {
    private func seed(_ store: TranscriptStore, now: Date) throws {
        // About three weeks of history with a gap, speeds around 150 to 190 WPM, one big day and one secure take.
        for daysAgo in 0..<21 where daysAgo != 5 && daysAgo != 6 {
            for take in 0..<(1 + daysAgo % 3) {
                let words = 18 + (daysAgo * 37 + take * 61) % 140 + (daysAgo == 9 ? 320 : 0)
                let wpm = 150 + Double((daysAgo * 7 + take * 13) % 45)
                let ms = Int(Double(words) / wpm * 60_000)
                let started = now.addingTimeInterval(-Double(daysAgo) * 86_400 - Double(take) * 1_800 - 600)
                let id = try store.begin(DictationStart(startedAt: started, target: DictationTarget(appName: "Notes")))
                try store.recordCapture(id, CaptureRecord(audioMs: ms + 800, voicedMs: ms))
                try store.recordInsertion(id, InsertionRecord(finalText: Array(repeating: "word", count: words).joined(separator: " ")))
            }
        }
        let secure = try store.begin(DictationStart(startedAt: now.addingTimeInterval(-300), target: DictationTarget(isSecure: true)))
        try store.recordInsertion(secure, InsertionRecord(finalText: Array(repeating: "secret", count: 900).joined(separator: " ")))
    }

    @Test func statsAndRecordsRenderInTheWindowShell() async throws {
        FontRegistry.registerBundledFonts()
        let name = "StatsSidebarRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-stats-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        try seed(store, now: Date())
        let stats = StatsModel(store: store, observing: false)
        await stats.load()
        #expect(stats.snapshot?.report.wordsAllTime ?? 0 < 5_000, "the secure take must not be counted")
        let model = SettingsModel(defaults: defaults, stats: stats)
        let size = NSSize(width: 1000, height: 1100)
        for (page, label) in [(SettingsPage.stats, "stats")] {
            model.page = page
            for dark in [false, true] {
                let bitmap = try SettingsRender.render(model: model, actions: SettingsActions(), dark: dark, size: size)
                let png = try #require(bitmap.representation(using: .png, properties: [:]))
                try png.write(to: URL(fileURLWithPath: "/tmp/mouthtype-\(label)-\(dark ? "dark" : "light").png"))
            }
        }
        // Empty history shows a plain empty state.
        let empty = StatsModel(store: try TranscriptStore(url: dir.appendingPathComponent("empty.sqlite")), observing: false)
        await empty.load()
        #expect(empty.snapshot?.hasHistory == false)
        let emptyModel = SettingsModel(defaults: defaults, stats: empty)
        emptyModel.page = .stats
        _ = try SettingsRender.render(model: emptyModel, actions: SettingsActions(), dark: false)
    }
}
