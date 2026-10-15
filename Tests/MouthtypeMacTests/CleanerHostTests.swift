import AppKit
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@Suite struct SmartLaunchOptionsTests {
    @Test func normalLaunchLeavesTheModelBudgetUnchanged() {
        let normal: (@Sendable (Int) -> Duration)? = SmartTestOptions.budget(in: ["Mouthtype"])
        let invalid: (@Sendable (Int) -> Duration)? = SmartTestOptions.budget(in: ["Mouthtype", "--smart-timeout-ms", "invalid"])
        #expect(normal == nil)
        #expect(invalid == nil)
    }

    @Test func diagnosticLaunchCanOverrideTheModelBudget() {
        let budget: (@Sendable (Int) -> Duration)? = SmartTestOptions.budget(in: ["Mouthtype", "--smart-timeout-ms", "9000"])
        #expect(budget?(3) == .milliseconds(9000))
    }
}

/// Holds a download open until `release()`.
actor DownloadGate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        open = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// A stand-in for the model: on disk or not, loads when told, counts what happens.
final class FakeSmartModel: SmartModel, @unchecked Sendable {
    let id: String
    let displayName: String
    let downloadSizeMB = 1447
    private let lock = NSLock()
    private var _downloaded: Bool
    private var _loaded = false
    private(set) var loads = 0
    private(set) var unloads = 0
    private(set) var downloads = 0
    var loadDelay: Duration = .zero
    var loadError: Error?
    var progressSteps: [Double] = [0.25, 0.5, 1]
    var downloadGate: DownloadGate?
    var unloadGate: DownloadGate?

    init(downloaded: Bool, id: String = "fake-model", name: String = "Fake") {
        _downloaded = downloaded; self.id = id; displayName = name
    }

    var isDownloaded: Bool { lock.withLock { _downloaded } }
    var isLoaded: Bool { lock.withLock { _loaded } }
    var revision: String? { "abc123" }

    func prepare() async throws {}

    func clean(_ transcript: String, context: CleanupContext) async throws -> String { transcript }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { downloads += 1 }
        for step in progressSteps { progress(step) }
        await downloadGate?.wait()
        lock.withLock { _downloaded = true }
    }

    func load() async throws {
        try await Task.sleep(for: loadDelay)
        if let loadError { throw loadError }
        lock.withLock {
            loads += 1
            _loaded = true
        }
    }

    func unload() async {
        await unloadGate?.wait()
        lock.withLock {
            unloads += 1
            _loaded = false
        }
    }
}

@MainActor
@Suite struct CleanerHostTests {
    @Test func switchingBackToLightWaitsForTheEarlierUnload() async {
        let gate = DownloadGate()
        let (host, model, level) = host(downloaded: true) { $0.unloadGate = gate }
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        level.value = .basic
        host.levelChanged()
        level.value = .light
        host.levelChanged()
        for _ in 0..<50 { await Task.yield() }
        #expect(model.loads == 1)
        await gate.release()
        await settle(host) { if case .ready = $0 { true } else { false } }
        #expect(model.loads == 2 && model.unloads == 1 && model.isLoaded)
    }

    private final class Level {
        var value = CleanupLevel.light
    }

    private func host(
        downloaded: Bool, level: CleanupLevel = .light, configure: (FakeSmartModel) -> Void = { _ in }
    ) -> (CleanerHost, FakeSmartModel, Level) {
        let model = FakeSmartModel(downloaded: downloaded)
        configure(model)
        let current = Level()
        current.value = level
        return (CleanerHost(model: model, level: { current.value }), model, current)
    }

    private func settle(_ host: CleanerHost, until done: (CleanerState) -> Bool) async {
        for _ in 0..<200 where !done(host.state) { try? await Task.sleep(for: .milliseconds(10)) }
    }

    @Test func aModelThatIsNotOnDiskStaysAbsentAndNothingIsFetched() async {
        let (host, model, _) = host(downloaded: false)
        host.start()
        host.recordingStarted()
        host.levelChanged()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.state == .absent && model.downloads == 0 && model.loads == 0)
        #expect(await host.readiness(waitingUpTo: .milliseconds(10)) == nil)
    }

    @Test func aModelOnDiskLoadsAtLaunchWhenTheLevelNeedsIt() async {
        let (host, model, _) = host(downloaded: true)
        #expect(host.state == .unloaded)
        host.start()
        #expect(host.state == .loading)
        await settle(host) { if case .ready = $0 { true } else { false } }
        guard case .ready = host.state else { Issue.record("not ready: \(host.state)"); return }
        #expect(model.loads == 1)
        let info = await host.readiness(waitingUpTo: .milliseconds(10))
        #expect(info == SmartCleanerInfo(id: "fake-model", revision: "abc123"))
    }

    @Test(arguments: [CleanupLevel.off, .basic])
    func levelsWithoutTheModelDoNotLoadIt(level: CleanupLevel) async {
        let (host, model, _) = host(downloaded: true, level: level)
        host.start()
        host.recordingStarted()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(host.state == .unloaded && model.loads == 0)
    }

    @Test func droppingToBasicUnloadsAndLightLoadsAgain() async {
        let (host, model, level) = host(downloaded: true)
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        level.value = .basic
        host.levelChanged()
        await settle(host) { $0 == .unloaded && model.unloads == 1 && !model.isLoaded }
        #expect(host.state == .unloaded && model.unloads == 1 && !model.isLoaded)
        level.value = .medium
        host.levelChanged()
        await settle(host) { if case .ready = $0 { true } else { false } }
        #expect(model.loads == 2 && model.isLoaded)
    }

    @Test func memoryPressureUnloadsAndTheNextRecordingReloads() async {
        let (host, model, _) = host(downloaded: true)
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        host.unloadForMemoryPressure()
        #expect(host.state == .unloaded)
        host.recordingStarted()
        await settle(host) { if case .ready = $0 { true } else { false } }
        #expect(model.loads == 2 && model.unloads == 1)
    }

    @Test func aLoadInProgressIsWaitedForUpToTheLimit() async {
        let (host, _, _) = host(downloaded: true) { $0.loadDelay = .milliseconds(120) }
        host.start()
        #expect(await host.readiness(waitingUpTo: .milliseconds(20)) == nil)
        #expect(await host.readiness(waitingUpTo: .seconds(2)) != nil)
    }

    @Test func aFailedLoadIsPublishedAndRetriedOnTheNextLevelChange() async {
        struct Broken: Error, LocalizedError { var errorDescription: String? { "no metallib" } }
        let (host, model, _) = host(downloaded: true) { $0.loadError = Broken() }
        host.start()
        await settle(host) { if case .failed = $0 { true } else { false } }
        #expect(host.state == .failed(message: "no metallib"))
        #expect(await host.readiness(waitingUpTo: .milliseconds(10)) == nil)
        model.loadError = nil
        host.levelChanged()
        await settle(host) { if case .ready = $0 { true } else { false } }
        if case .ready = host.state {} else { Issue.record("not ready: \(host.state)") }
    }

    @Test func downloadingPublishesProgressThenLoads() async {
        let gate = DownloadGate()
        let (host, model, _) = host(downloaded: false) { $0.downloadGate = gate }
        host.startDownload()
        await settle(host) { if case .downloading(let f) = $0 { f >= 1 } else { false } }
        #expect(host.state == .downloading(fraction: 1))
        host.startDownload()
        #expect(model.downloads == 1, "a second tap doesn't start a second download")
        await gate.release()
        await settle(host) { if case .ready = $0 { true } else { false } }
        if case .ready = host.state {} else { Issue.record("not ready: \(host.state)") }
        #expect(model.isDownloaded && model.loads == 1)
    }

    @Test func aDownloadAtBasicLeavesTheModelOnDiskUnloaded() async {
        let (host, model, _) = host(downloaded: false, level: .basic)
        host.startDownload()
        await settle(host) { $0 == .unloaded }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(host.state == .unloaded && model.isDownloaded && model.loads == 0)
    }
}

@MainActor
@Suite struct CleanupMenuModelTests {
    private func defaults() -> UserDefaults {
        let suite = "mouthtype.cleanup.model.tests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func make(
        downloaded: Bool, level: CleanupLevel = .light, d: UserDefaults? = nil, confirm: @escaping @MainActor (Int) -> Bool = { _ in true }
    ) -> (CleanupMenuSection, CleanerHost, FakeSmartModel, NSMenu) {
        let d = d ?? defaults()
        var settings = CleanupSettings()
        settings.level = level
        settings.save(to: d)
        let model = FakeSmartModel(downloaded: downloaded)
        let host = CleanerHost(model: model, level: { CleanupSettings.load(d).level })
        let section = CleanupMenuSection(defaults: d, cleaner: host, confirmDownload: { _, size in confirm(size) })
        return (section, host, model, section.items[0].submenu!)
    }

    private func item(_ menu: NSMenu, prefix: String) -> NSMenuItem? { menu.items.first { $0.title.hasPrefix(prefix) } }

    @Test func anAbsentModelShowsItsNameStateAndSizeBeforeDownloading() {
        let (section, _, _, menu) = make(downloaded: false)
        #expect(item(menu, prefix: "Fake: not downloaded")?.isHidden == false)
        let download = item(menu, prefix: "Download Smart Cleanup Model")
        #expect(download?.title == "Download Smart Cleanup Model\u{2026} (1.4 GB)" && download?.isHidden == false)
        #expect(item(menu, prefix: "Smart cleanup isn't ready")?.isHidden == false)
        withExtendedLifetime(section) {}
    }

    @Test func theMenuNamesTheSelectedQualityModel() {
        #expect(CleanerCatalog.smartCleanupName == "Gemma 4 E4B")
        let (section, host, _, menu) = make(downloaded: false)
        #expect(host.modelName == "Fake")
        #expect(menu.items.contains { $0.title.hasPrefix("Fake:") })
        withExtendedLifetime(section) {}
    }

    @Test func aReadyModelHidesTheDownloadItemAndTheFallbackLine() async {
        let (section, host, _, menu) = make(downloaded: true)
        host.start()
        for _ in 0..<100 { if case .ready = host.state { break }; try? await Task.sleep(for: .milliseconds(10)) }
        section.refresh()
        #expect(item(menu, prefix: "Fake: ready") != nil)
        #expect(item(menu, prefix: "Download Smart Cleanup Model")?.isHidden == true)
        #expect(item(menu, prefix: "Smart cleanup isn't ready")?.isHidden == true)
    }

    @Test func theFallbackLineOnlyShowsForLevelsThatNeedTheModel() {
        let (section, _, _, menu) = make(downloaded: false, level: .basic)
        #expect(item(menu, prefix: "Smart cleanup isn't ready")?.isHidden == true)
        withExtendedLifetime(section) {}
    }

    @Test func choosingDownloadAsksFirstAndDeclineFetchesNothing() {
        var asked: [Int] = []
        let (section, host, model, menu) = make(downloaded: false) { asked.append($0); return false }
        let download = item(menu, prefix: "Download Smart Cleanup Model")!
        _ = download.target?.perform(download.action, with: download)
        #expect(asked == [1447] && host.state == .absent && model.downloads == 0)
        withExtendedLifetime(section) {}
    }

    @Test func confirmingStartsTheDownload() async {
        let (section, host, model, menu) = make(downloaded: false, level: .basic)
        let download = item(menu, prefix: "Download Smart Cleanup Model")!
        _ = download.target?.perform(download.action, with: download)
        for _ in 0..<100 where model.downloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.downloads == 1)
        for _ in 0..<100 where host.state != .unloaded { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(host.state == .unloaded)
        withExtendedLifetime(section) {}
    }

    @Test func pickingALevelTellsTheHost() async {
        let d = defaults()
        let (section, host, model, menu) = make(downloaded: true, level: .basic, d: d)
        host.start()
        try? await Task.sleep(for: .milliseconds(30))
        #expect(model.loads == 0)
        let light = menu.items.first { $0.title == "Fast" }!
        _ = light.target?.perform(light.action, with: light)
        for _ in 0..<100 where model.loads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.loads == 1 && CleanupSettings.load(d).level == .light)
        withExtendedLifetime(section) {}
    }
}
