import AppKit
import Testing
import SwiftUI
@testable import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite(.serialized) struct HomeRenderTests {
    @Test func homeRendersSampleTakesWithoutTruncatingText() async throws {
        let name = "HomeRenderTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-home-render-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
        let now = Date()
        let samples: [(Double, String, String?)] = [
            (1, "Can you move the review to Thursday afternoon? I have the planning call until two.", "Slack"),
            (9, "Remember to send Priya the updated agenda before the end of the day, and loop in Hove on the build status so nobody is surprised tomorrow morning when the release notes go out.", "Mail"),
            (26, "Pick up oat milk, the good bread, and those batteries.", "Notes"),
        ]
        for (minutesAgo, text, app) in samples {
            let id = try store.begin(DictationStart(startedAt: now.addingTimeInterval(-minutesAgo * 60), target: DictationTarget(appName: app)))
            try store.recordInsertion(id, InsertionRecord(finalText: text))
        }
        let home = HomeLogModel(store: store)
        await home.loadText()
        home.attach([RecoverableDictation(id: "sample-lost", startedAt: now.addingTimeInterval(-14 * 60),
            audioURL: URL(fileURLWithPath: "/tmp/sample.wav"), seconds: 7, isPartial: false)])
        #expect(home.takes.count == 4)
        #expect(home.takes.compactMap(\.text).contains(samples[1].1))
        let model = SettingsModel(defaults: defaults, home: home)
        let actions = SettingsActions()
        model.page = .home
        let bitmap = try SettingsRender.render(model: model, actions: actions, dark: false)
        #expect(bitmap.pixelsWide >= 900 && bitmap.pixelsHigh >= 620)
        try SettingsRender.save(bitmap, name: "home-light")
        try SettingsRender.save(try SettingsRender.render(model: model, actions: actions, dark: true), name: "home-dark")
        model.page = .general
        try SettingsRender.save(try SettingsRender.render(model: model, actions: actions, dark: false), name: "general-light")
    }
}
