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

    @Test func aRealKeyDownResetsTheIdleCountdownOfAReadyModel() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast")
        let selection = CleanupSelection(
            fast: fast, thorough: FakeSmartModel(downloaded: true, id: "thorough"), level: { choice.level },
            idleUnloadDelay: .seconds(4))
        selection.start()
        for _ in 0..<200 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(2500))
        selection.recordingStarted(level: .light, take: "take-1")
        try? await Task.sleep(for: .milliseconds(2500))
        // 5 s since ready, past the 4 s delay, but the key-down was only 2.5 s ago: a second of slack either way.
        #expect(fast.isLoaded && fast.unloads == 0)
        selection.releasePrewarm(for: "take-1")
        for _ in 0..<1500 where fast.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.unloads == 1)
    }

    private func idleSelection(_ delay: Duration) -> (CleanupSelection, FakeSmartModel) {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast")
        let selection = CleanupSelection(
            fast: fast, thorough: FakeSmartModel(downloaded: true, id: "thorough"), level: { choice.level },
            idleUnloadDelay: delay)
        return (selection, fast)
    }

    @Test func theModelStaysLoadedPastTheIdleDelayWhileARecordingIsActive() async {
        let (selection, fast) = idleSelection(.milliseconds(300))
        selection.start()
        selection.recordingStarted(level: .light, take: "long")
        for _ in 0..<500 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.isLoaded)
        // Several times the delay with the take still recording.
        try? await Task.sleep(for: .milliseconds(1500))
        #expect(fast.isLoaded && fast.unloads == 0)
        selection.releasePrewarm(for: "long")
    }

    @Test func theModelUnloadsAfterTheIdleDelayOnceTheRecordingEnds() async {
        let (selection, fast) = idleSelection(.milliseconds(300))
        selection.start()
        selection.recordingStarted(level: .light, take: "take")
        for _ in 0..<500 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(900))
        #expect(fast.unloads == 0)
        selection.releasePrewarm(for: "take")
        for _ in 0..<1000 where fast.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.unloads == 1 && !fast.isLoaded)
    }

    @Test func aCancelledRecordingReleasesItsHold() async {
        let (selection, fast) = idleSelection(.milliseconds(300))
        selection.start()
        selection.recordingStarted(level: .light, take: "cancelled")
        for _ in 0..<500 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        try? await Task.sleep(for: .milliseconds(600))
        #expect(fast.unloads == 0)
        // A cancelled take releases the same way a finished one does, and a second release changes nothing.
        selection.releasePrewarm(for: "cancelled")
        selection.releasePrewarm(for: "cancelled")
        for _ in 0..<1000 where fast.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.unloads == 1 && !fast.isLoaded)
    }

    @Test func aTakeReplacingItsLevelDoesNotLeakTheEarlierHold() async {
        let (selection, fast) = idleSelection(.milliseconds(300))
        selection.start()
        selection.recordingStarted(level: .light, take: "a")
        selection.recordingStarted(level: .light, take: "a")
        for _ in 0..<500 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        selection.releasePrewarm(for: "a")
        for _ in 0..<1000 where fast.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(fast.unloads == 1)
    }

    @Test func readinessAndGenerationUseTheCapturedLevel() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast", name: "S1-mini by Superwhisper")
        let thorough = FakeSmartModel(downloaded: true, id: "thorough", name: "Gemma")
        let selection = CleanupSelection(fast: fast, thorough: thorough, level: { choice.level })
        selection.start()
        let captured = SmartCleanupRequest(text: "This is a sentence.", level: .light)
        choice.level = .medium
        selection.levelChanged()
        let delivery = await selection.runReady(captured, waitingUpTo: .seconds(60))
        #expect(delivery?.model.id == "fast")
        #expect(delivery?.result.text == "This is a sentence.")
        let next = await selection.runReady(SmartCleanupRequest(text: "Another sentence.", level: .medium), waitingUpTo: .seconds(60))
        #expect(next?.model.id == "thorough")
        for _ in 0..<6000 where fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!fast.isLoaded)
        #expect(thorough.isLoaded)
    }

    @Test func aSelectionChangeDuringLoadingKeepsTheCapturedModelAvailable() async {
        let choice = Choice()
        let fast = FakeSmartModel(downloaded: true, id: "fast")
        let gate = DownloadGate()
        fast.loadGate = gate
        let selection = CleanupSelection(fast: fast, thorough: FakeSmartModel(downloaded: true, id: "thorough"), level: { choice.level })
        let request = Task { await selection.runReady(SmartCleanupRequest(text: "Keep the wording.", level: .light), waitingUpTo: .seconds(60)) }
        for _ in 0..<6000 where fast.loadsStarted == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        choice.level = .medium; selection.levelChanged()
        await gate.release()
        #expect(await request.value?.model.id == "fast")
        for _ in 0..<6000 where fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!fast.isLoaded)
    }

    private func settle() async { try? await Task.sleep(for: .milliseconds(300)) }

    @Test func aRuleLevelPrewarmsTheModelAndHoldsItForTheTake() async {
        let thorough = FakeSmartModel(downloaded: true, id: "thorough")
        thorough.loadDelay = .milliseconds(150)
        let selection = CleanupSelection(
            fast: FakeSmartModel(downloaded: true, id: "fast"), thorough: thorough, level: { .off })
        selection.start()
        selection.recordingStarted(level: .medium, take: "a")
        for _ in 0..<600 where !thorough.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        // Well past the old 120 s window's worth of settling: nothing but the take's end releases it.
        await settle()
        #expect(thorough.isLoaded)
        #expect(thorough.unloads == 0)
        selection.releasePrewarm(for: "a")
        for _ in 0..<600 where thorough.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(thorough.unloads == 1)
        #expect(!thorough.isLoaded)
    }

    @Test func releasingATakeThatNeverLoadedLeavesNothingBehind() async {
        let thorough = FakeSmartModel(downloaded: true, id: "thorough")
        let selection = CleanupSelection(fast: FakeSmartModel(downloaded: true, id: "fast"), thorough: thorough, level: { .off })
        selection.start()
        selection.releasePrewarm(for: "unknown")
        selection.recordingStarted(level: .medium, take: "a")
        selection.releasePrewarm(for: "a")
        selection.releasePrewarm(for: "a")
        await settle()
        for _ in 0..<600 where thorough.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!thorough.isLoaded)
    }

    @Test func aWebsiteRuleReplacesTheTakesHoldInsteadOfAddingOne() async {
        let fast = FakeSmartModel(downloaded: true, id: "fast")
        let thorough = FakeSmartModel(downloaded: true, id: "thorough")
        let selection = CleanupSelection(fast: fast, thorough: thorough, level: { .off })
        selection.start()
        selection.recordingStarted(level: .light, take: "a")
        for _ in 0..<600 where !fast.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        selection.recordingStarted(level: .medium, take: "a")
        for _ in 0..<600 where fast.isLoaded || !thorough.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!fast.isLoaded)
        #expect(thorough.isLoaded)
        selection.releasePrewarm(for: "a")
        for _ in 0..<600 where thorough.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(!thorough.isLoaded)
        #expect(fast.loads == 1)
    }

    @Test func releasingAfterAMemoryPressureUnloadDoesNotReload() async {
        let thorough = FakeSmartModel(downloaded: true, id: "thorough")
        let host = CleanupSelection(fast: FakeSmartModel(downloaded: true, id: "fast"), thorough: thorough, level: { .off })
        host.start()
        host.recordingStarted(level: .medium, take: "a")
        for _ in 0..<600 where !thorough.isLoaded { try? await Task.sleep(for: .milliseconds(10)) }
        let unloadedByPressure = thorough.unloads
        // Stand-in for memory pressure: the host drops the model while the take still holds it.
        host.unloadThoroughForMemoryPressure()
        for _ in 0..<600 where thorough.unloads == unloadedByPressure { try? await Task.sleep(for: .milliseconds(10)) }
        let loads = thorough.loads
        host.releasePrewarm(for: "a")
        await settle()
        #expect(thorough.loads == loads)
        #expect(!thorough.isLoaded)
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
        let item = section.items[0].submenu!.items.first { $0.title.hasPrefix("Download Cleanup") }!
        _ = item.target?.perform(item.action, with: item)
        for _ in 0..<6000 where fast.downloads + thorough.downloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
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
        let download = menu.items.first { $0.title.hasPrefix("Download Cleanup") }!
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

@MainActor
@Suite struct TransformModelStatusTests {
    private func selection(fast: Bool, thorough: Bool, level: CleanupLevel) -> CleanupSelection {
        CleanupSelection(fast: FakeSmartModel(downloaded: fast, id: "fast", name: "S1-mini"),
                         thorough: FakeSmartModel(downloaded: thorough, id: "thorough", name: "Gemma"), level: { level })
    }

    @Test func fastOnlyWithFastSelectedStillReportsThoroughMissing() {
        let selection = selection(fast: true, thorough: false, level: .light)
        selection.start()
        #expect(selection.state != .absent)
        let status = selection.transformModelStatus
        #expect(status.state == .absent)
        #expect(status.modelName == "Gemma")
        #expect(!status.isReady)
        #expect(status.stateWord == "NOT DOWNLOADED")
        #expect(selection.transformUnavailableReason == status.unavailableReason)
    }

    @Test func thoroughOnlyWithThoroughNotSelectedStillReportsReady() {
        let selection = selection(fast: false, thorough: true, level: .light)
        selection.start()
        #expect(selection.state == .absent)
        let status = selection.transformModelStatus
        #expect(status.state != .absent)
        #expect(status.modelName == "Gemma")
        #expect(status.isReady)
        #expect(status.stateWord == "READY")
        #expect(selection.transformUnavailableReason == nil)
    }

    @Test func downloadingStateShowsPercentAndBlocks() {
        let status = TransformModelStatus(state: .downloading(fraction: 0.4), modelName: "Gemma")
        #expect(!status.isReady)
        #expect(status.stateWord == "DOWNLOADING 40%")
        #expect(status.unavailableReason?.contains("downloading") == true)
        #expect(TransformModelStatus(state: .downloading(fraction: 2), modelName: "Gemma").stateWord == "DOWNLOADING 100%")
    }
}
