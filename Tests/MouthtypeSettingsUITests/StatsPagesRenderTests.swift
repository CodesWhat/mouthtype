import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct StatsPagesRenderTests {
    static let sample: [DictationSample] = {
        var out: [DictationSample] = []
        
        for offset in 0..<18 where offset != 6 && offset != 7 {
            let words = 120 + (offset * 53) % 400
            out.append(DictationSample(day: String(format: "2026-10-%02d", 1 + offset), startedAt: Date(timeIntervalSince1970: Double(offset)),
                                       words: words, durationMs: words * 420))
        }
        out.append(DictationSample(day: "2026-10-12", startedAt: Date(timeIntervalSince1970: 100), words: 640, durationMs: 190_000))
        return out
    }()

    private func render(_ page: some View, dark: Bool = false, path: String?) throws {
        let size = NSSize(width: 640, height: 820)
        let view = NSHostingView(rootView: AnyView(page.frame(width: size.width, height: size.height)
            .background(Color(nsColor: .windowBackgroundColor)).environment(\.colorScheme, dark ? .dark : .light)))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        view.setFrameSize(size)
        view.layoutSubtreeIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        #expect(bitmap.pixelsWide >= Int(size.width))
        if let path { try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path)) }
    }

    private var previews: Bool { ProcessInfo.processInfo.environment["MOUTHTYPE_STATS_PREVIEWS"] != nil }

    @Test func statsPageRenders() throws {
        FontRegistry.registerBundledFonts()
        let engine = StatsEngine(samples: Self.sample)
        let report = engine.report(today: "2026-10-18")
        #expect(report.wordsAllTime > 0)
        try render(StatsPage(report: report, daily: engine.dailyWords(from: "2026-10-05", to: "2026-10-18")),
                   path: previews ? "/tmp/mouthtype-stats-preview.png" : nil)
    }

    @Test func recordsPageRendersWithAndWithoutRecords() throws {
        FontRegistry.registerBundledFonts()
        let records = StatsEngine(samples: Self.sample).records()
        #expect(records.wpm != nil && records.longestStreak != nil)
        try render(RecordsPage(records: records), path: previews ? "/tmp/mouthtype-records-preview.png" : nil)
        try render(RecordsPage(records: ArcadeRecords()), dark: true, path: nil)
        try render(StatsPage(report: StatsEngine(samples: []).report(today: "2026-10-18"), daily: []), path: nil)
    }

    @Test func formatterHandlesEdges() {
        #expect(StatsFormat.date("2026-10-03") == "Oct 3, 2026")
        #expect(StatsFormat.date("junk") == "junk")
        #expect(StatsFormat.duration(minutes: 125) == "2 h 5 min")
        #expect(StatsFormat.duration(minutes: 0) == "None yet")
        #expect(StatsFormat.duration(minutes: 0.2) == "Under a minute")
        #expect(StatsFormat.speaking(ms: 190_000) == "3 min 10 s")
    }

    @Test func emptyWindowHidesTheBusiestLabel() {
        #expect(DailyBars.caption(busiest: 0) == "No takes in the last 14 days")
        #expect(DailyBars.caption(busiest: 1) == "Busiest: 1 words")
        #expect(DailyBars.caption(busiest: 1_234) == "Busiest: \(StatsFormat.number(1_234)) words")
    }
}
