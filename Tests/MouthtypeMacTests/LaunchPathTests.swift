import AppKit
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct LaunchPathTests {
    private func defaults() -> (UserDefaults, () -> Void) {
        let name = "LaunchPathTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func backgroundRegistrationFinishesBeforeADrawPathReturns() async {
        FontRegistry.registerInBackground()
        // Draw paths gate on ensureRegistered, which waits for the background pass instead of reading a half-registered set.
        FontRegistry.ensureRegistered()
        #expect(FontRegistry.registered == FontRegistry.families)
        #expect(Typography.systemaAvailable)
        #expect(NSFont(name: FontRegistry.monoName, size: 9) != nil)
    }

    @Test func registrationIsSafeFromOtherThreads() async {
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<4 { group.addTask { FontRegistry.registerBundledFonts() } }
            var all: [[String]] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.allSatisfy { $0 == FontRegistry.families })
    }

    @Test func settingsModelsStayUnbuiltUntilFirstPresentAndThenGetTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let delegate = AppDelegate()
        delegate.settingsStore = store
        #expect(!delegate.settingsWindowBuilt)
        let window = delegate.settingsWindow
        #expect(delegate.settingsWindowBuilt)
        #expect(window.model.home.store === store)
        #expect(window.model.stats.store === store)
        #expect(window.model.spellingSuggestions?.store === store)
    }

    @Test func burstsOfRefreshRequestsRunOnce() async {
        let (defaults, cleanup) = defaults()
        defer { cleanup() }
        let model = SettingsModel(defaults: defaults)
        let before = model.refreshCount
        for _ in 0..<20 { model.scheduleRefresh() }
        #expect(model.refreshCount == before)
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshCount == before + 1)
    }

    @Test func anImmediateRefreshCoversAPendingRequest() async {
        let (defaults, cleanup) = defaults()
        defer { cleanup() }
        let model = SettingsModel(defaults: defaults)
        let before = model.refreshCount
        model.scheduleRefresh()
        model.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshCount == before + 1)
    }

    @Test func fontFamiliesAreListedOnceUntilTheFontSetChanges() {
        FontFamilyCache.invalidate()
        let start = FontFamilyCache.loads
        let first = FontFamilyCache.families()
        #expect(FontFamilyCache.families() == first)
        #expect(FontFamilyCache.loads == start + 1)
        NotificationCenter.default.post(name: Notification.Name("NSFontSetChangedNotification"), object: nil)
        _ = FontFamilyCache.families()
        #expect(FontFamilyCache.loads == start + 2)
    }
}

@Suite struct PhrasesHealthTests {
    @Test func theFileIsReadAgainOnlyWhenItChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phrases-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("phrases.json")
        let phrases = FilePhrases(url: url)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthReads.withLock { $0 } == 1)
        try Data("not json".utf8).write(to: url)
        #expect(phrases.healthError() != nil)
        #expect(phrases.healthError() != nil)
        #expect(phrases.healthReads.withLock { $0 } == 2)
        try Data("[]\n".utf8).write(to: url)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthReads.withLock { $0 } == 3)
    }
}
