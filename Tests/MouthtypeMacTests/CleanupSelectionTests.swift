import AppKit
import Foundation
import Observation
import Synchronization
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct CleanupSelectionTests {
    @Test func persistedLevelsSelectModelsWithoutChangingTone() {
        #expect(CleanupLevel.light.title == "Fast")
        #expect(CleanupLevel.medium.title == "Thorough")
        #expect(CleanerCatalog.smartCleanupID(for: .light) == "superwhisper-s1-mini")
        #expect(CleanerCatalog.smartCleanupID(for: .medium) == "gemma-4-e4b-it-4bit")
        #expect(CleanupLevel(rawValue: "light") == .light)
        #expect(CleanupLevel(rawValue: "medium") == .medium)
        let host = CleanerHost(model: CleanerCatalog.makeSmartCleanup(level: .light), level: { .light })
        #expect(host.modelName == "S1-mini by Superwhisper")
    }

    private final class Choice { var level = CleanupLevel.light }

    @Test func readinessAndGenerationUseTheCapturedLevel() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast", name: "S1-mini by Superwhisper")
        let thorough = FakeSmartModel(downloaded: true, id: "thorough", name: "Gemma")
        let selection = CleanupSelection(fast: fast, thorough: thorough, level: { choice.level })
        selection.start()
        let captured = SmartCleanupRequest(text: "This is a sentence.", level: .light)
        choice.level = .medium
        selection.levelChanged()
        let delivery = await selection.runReady(captured, waitingUpTo: .seconds(2))
        #expect(delivery?.model.id == "fast")
        #expect(delivery?.result.text == "This is a sentence.")
        let next = await selection.runReady(SmartCleanupRequest(text: "Another sentence.", level: .medium), waitingUpTo: .seconds(2))
        #expect(next?.model.id == "thorough")
        for _ in 0..<100 where fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!fast.isLoaded)
        #expect(thorough.isLoaded)
    }

    @Test func aSelectionChangeDuringLoadingKeepsTheCapturedModelAvailable() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast")
        fast.loadDelay = .milliseconds(80)
        let selection = CleanupSelection(fast: fast, thorough: FakeSmartModel(downloaded: true, id: "thorough"), level: { choice.level })
        let request = Task { await selection.runReady(SmartCleanupRequest(text: "Keep the wording.", level: .light), waitingUpTo: .seconds(2)) }
        try? await Task.sleep(for: .milliseconds(20))
        choice.level = .medium; selection.levelChanged()
        #expect(await request.value?.model.id == "fast")
        for _ in 0..<100 where fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!fast.isLoaded)
    }

    @Test func unavailableFastDoesNotDownloadOrUseThorough() async {
        let fast = FakeSmartModel(downloaded: false, id: "fast", name: "Fast model")
        let thorough = FakeSmartModel(downloaded: true, id: "thorough", name: "Thorough model")
        let selection = CleanupSelection(fast: fast, thorough: thorough, level: { .light })
        selection.start()
        #expect(await selection.runReady(SmartCleanupRequest(text: "Keep this sentence.", level: .light), waitingUpTo: .milliseconds(20)) == nil)
        #expect(fast.downloads == 0)
        #expect(thorough.loads == 0)
    }

    @Test func observationFollowsASelectionWhosePreviousModelWasAbsent() {
        let choice = Choice()
        let selection = CleanupSelection(
            fast: FakeSmartModel(downloaded: false), thorough: FakeSmartModel(downloaded: false), level: { choice.level })
        let changed = Mutex(false)
        withObservationTracking { _ = selection.state } onChange: { changed.withLock { $0 = true } }
        choice.level = .medium
        selection.levelChanged()
        selection.startDownload()
        #expect(changed.withLock { $0 })
    }

    @Test func confirmationDownloadsTheModelThatWasShown() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: false, id: "fast")
        let thorough = FakeSmartModel(downloaded: false, id: "thorough")
        let selection = CleanupSelection(fast: fast, thorough: thorough, level: { choice.level })
        let suite = "mouthtype-confirm-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let section = CleanupMenuSection(defaults: defaults, cleaner: selection, confirmDownload: { _, _ in
            choice.level = .medium; return true
        })
        let item = section.items[0].submenu!.items.first { $0.title.hasPrefix("Download Smart Cleanup") }!
        _ = item.target?.perform(item.action, with: item)
        for _ in 0..<100 where fast.downloads + thorough.downloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.downloads == 1)
        #expect(thorough.downloads == 0)
    }

    @Test func menuAndDownloadConfirmationFollowTheSelectedModel() {
        let choice = Choice()
        let selection = CleanupSelection(
            fast: FakeSmartModel(downloaded: false, id: "fast", name: "S1-mini by Superwhisper"),
            thorough: FakeSmartModel(downloaded: false, id: "thorough", name: "Gemma 4 E4B"), level: { choice.level })
        let suite = "mouthtype-selection-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = CleanupSettings(); saved.style = StylePreset.veryCasual.options; saved.save(to: defaults)
        var names: [String] = []
        let section = CleanupMenuSection(defaults: defaults, cleaner: selection, confirmDownload: { name, _ in names.append(name); return false })
        let menu = section.items[0].submenu!
        let download = menu.items.first { $0.title.hasPrefix("Download Smart Cleanup") }!
        _ = download.target?.perform(download.action, with: download)
        choice.level = .medium
        var settings = CleanupSettings.load(defaults); settings.level = .medium; settings.save(to: defaults)
        selection.levelChanged(); section.refresh()
        _ = download.target?.perform(download.action, with: download)
        #expect(names == ["S1-mini by Superwhisper", "Gemma 4 E4B"])
        #expect(CleanupSettings.load(defaults).style == StylePreset.veryCasual.options)
        #expect(menu.items.contains { $0.title == "Fast" })
        #expect(menu.items.contains { $0.title == "Thorough" })
    }
}
