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

    @Test func onlyPipelineSelfTestsOverrideTheHostModelChoice() {
        #expect(SmartTestOptions.modelLevel(in: ["Mouthtype", "--pipeline-selftest", "audio.wav", "--cleanup-level", "medium"], saved: .light) == .medium)
        #expect(SmartTestOptions.modelLevel(in: ["Mouthtype", "--cleanup-level", "medium"], saved: .light) == .light)
        #expect(SmartTestOptions.modelLevel(in: ["Mouthtype", "--pipeline-selftest", "audio.wav"], saved: .medium) == .medium)
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
    private(set) var cleanCalls = 0
    var loadDelay: Duration = .zero
    var loadError: Error?
    var progressSteps: [Double] = [0.25, 0.5, 1]
    var downloadGate: DownloadGate?
    var cleanGate: DownloadGate?
    var unloadGate: DownloadGate?
    var loadGate: DownloadGate?
    private(set) var loadsStarted = 0

    init(downloaded: Bool, id: String = "fake-model", name: String = "Fake") {
        _downloaded = downloaded; self.id = id; displayName = name
    }

    var isDownloaded: Bool { lock.withLock { _downloaded } }
    var isLoaded: Bool { lock.withLock { _loaded } }
    var revision: String? { "abc123" }

    func prepare() async throws {}

    func clean(_ transcript: String, context: CleanupContext) async throws -> String {
        lock.withLock { cleanCalls += 1 }
        await cleanGate?.wait()
        return transcript
    }

    func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        lock.withLock { downloads += 1 }
        for step in progressSteps { progress(step) }
        await downloadGate?.wait()
        lock.withLock { _downloaded = true }
    }

    func load() async throws {
        lock.withLock { loadsStarted += 1 }
        try await Task.sleep(for: loadDelay)
        await loadGate?.wait()
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
    @Test func newCleanupDuringUnloadFallsBackUntilTheModelIsReloaded() async {
        let gate = DownloadGate()
        let (host, model, level) = host(downloaded: true)
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        let before = model.cleanCalls
        model.unloadGate = gate
        level.value = .basic
        host.levelChanged()
        try? await Task.sleep(for: .milliseconds(40))
        let request = SmartCleanupRequest(text: "keep this take", level: .light)
        let during = await host.run(request)
        #expect(during.text == request.text && during.outcome == .skipped)
        #expect(model.cleanCalls == before)
        await gate.release()
        level.value = .light
        host.levelChanged()
        await settle(host) { if case .ready = $0 { true } else { false } }
        #expect(await host.run(request).outcome == .ok)
    }

    @Test func unloadWaitsForTheModelWorkAfterATimeout() async {
        let gate = DownloadGate()
        let model = FakeSmartModel(downloaded: true)
        let level = Level()
        let host = CleanerHost(model: model, level: { level.value }, budget: { _ in .milliseconds(20) })
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        model.cleanGate = gate
        let result = await host.run(SmartCleanupRequest(text: "keep this take", level: .light))
        #expect(result.outcome == .timeout)
        level.value = .basic
        host.levelChanged()
        try? await Task.sleep(for: .milliseconds(40))
        #expect(model.unloads == 0 && model.isLoaded)
        await gate.release()
        for _ in 0..<100 where model.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unloads == 1 && !model.isLoaded)
    }

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

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = false
        var value: Bool { lock.withLock { _value } }
        func set() { lock.withLock { _value = true } }
    }

    private func readyHost(
        budget: (@Sendable (Int) -> Duration)? = nil
    ) async -> (CleanerHost, FakeSmartModel, Level) {
        let model = FakeSmartModel(downloaded: true)
        let level = Level()
        let host = CleanerHost(model: model, level: { level.value }, budget: budget)
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        return (host, model, level)
    }

    @Test func cancellingReadinessStopsWaitingOnASuspendedLoad() async {
        let gate = DownloadGate()
        let model = FakeSmartModel(downloaded: true)
        model.loadGate = gate
        let level = Level()
        let host = CleanerHost(model: model, level: { level.value })
        host.start()
        await settle(host) { $0 == .loading }
        let finished = Flag()
        let waiting = Task { @MainActor in
            let info = await host.readiness(waitingUpTo: .seconds(60))
            finished.set()
            return info
        }
        try? await Task.sleep(for: .milliseconds(40))
        waiting.cancel()
        for _ in 0..<100 where !finished.value { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(finished.value)
        #expect(await waiting.value == nil)
        await gate.release()
        await settle(host) { if case .ready = $0 { true } else { false } }
    }

    @Test func aCancelledTransformNeverReachesTheModel() async {
        let gate = DownloadGate()
        let model = FakeSmartModel(downloaded: true)
        model.loadGate = gate
        let level = Level()
        let host = CleanerHost(model: model, level: { level.value })
        host.start()
        await settle(host) { $0 == .loading }
        let task = Task { @MainActor in try await host.transform(.shorter, text: "some text here", waitingUpTo: .seconds(60)) }
        try? await Task.sleep(for: .milliseconds(40))
        task.cancel()
        await gate.release()
        await settle(host) { if case .ready = $0 { true } else { false } }
        let calls = model.cleanCalls
        let outcome = await task.result
        #expect({ if case .failure = outcome { true } else { false } }())
        #expect(model.cleanCalls == calls)
    }

    @Test func memoryPressureUnloadWaitsForARunningTransform() async {
        let (host, model, _) = await readyHost()
        let gate = DownloadGate()
        model.cleanGate = gate
        let baseline = model.cleanCalls
        let task = Task { @MainActor in try await host.transform(.fixGrammar, text: "some text here", waitingUpTo: .seconds(5)) }
        for _ in 0..<100 where model.cleanCalls == baseline { try? await Task.sleep(for: .milliseconds(10)) }
        host.unloadForMemoryPressure()
        try? await Task.sleep(for: .milliseconds(60))
        #expect(model.unloads == 0 && model.isLoaded)
        await gate.release()
        #expect((try? await task.value) == "some text here")
        for _ in 0..<100 where model.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unloads == 1 && !model.isLoaded)
    }

    @Test func aNewTransformWaitsForACancelledOneToSettle() async {
        let (host, model, _) = await readyHost()
        let gate = DownloadGate()
        model.cleanGate = gate
        let baseline = model.cleanCalls
        let first = Task { @MainActor in try await host.transform(.shorter, text: "first text", waitingUpTo: .seconds(5)) }
        for _ in 0..<100 where model.cleanCalls == baseline { try? await Task.sleep(for: .milliseconds(10)) }
        first.cancel()
        let second = Task { @MainActor in try await host.transform(.shorter, text: "second text", waitingUpTo: .seconds(5)) }
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.cleanCalls == baseline + 1)
        await gate.release()
        #expect((try? await second.value) == "second text")
        #expect(model.cleanCalls == baseline + 2)
        _ = await first.result
    }

    @Test func dictationCleanupDoesNotRunOnTheModelWhileATransformHoldsIt() async {
        let (host, model, _) = await readyHost(budget: { _ in .milliseconds(30) })
        let gate = DownloadGate()
        model.cleanGate = gate
        let baseline = model.cleanCalls
        let task = Task { @MainActor in try await host.transform(.moreFormal, text: "some text here", waitingUpTo: .seconds(5)) }
        for _ in 0..<100 where model.cleanCalls == baseline { try? await Task.sleep(for: .milliseconds(10)) }
        let dictation = await host.run(SmartCleanupRequest(text: "keep this take", level: .light))
        #expect(dictation.outcome == .timeout && dictation.text == "keep this take")
        #expect(model.cleanCalls == baseline + 1)
        await gate.release()
        _ = try? await task.value
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
        let gate = DownloadGate()
        let (host, _, _) = host(downloaded: true) { $0.loadGate = gate }
        host.start()
        #expect(await host.readiness(waitingUpTo: .milliseconds(20)) == nil)
        Task { try? await Task.sleep(for: .milliseconds(50)); await gate.release() }
        // The limit is generous because it only bounds a hang; the release above is what ends the wait.
        #expect(await host.readiness(waitingUpTo: .seconds(60)) != nil)
    }

    private func idleHost(_ delay: Duration, configure: (FakeSmartModel) -> Void = { _ in }) -> (CleanerHost, FakeSmartModel) {
        let model = FakeSmartModel(downloaded: true)
        configure(model)
        return (CleanerHost(model: model, level: { .light }, budget: { _ in .seconds(60) }, idleUnloadDelay: delay), model)
    }

    @Test func theModelUnloadsAfterTheIdleDelay() async {
        let (host, model) = idleHost(.milliseconds(150))
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        await settle(host) { $0 == .unloaded }
        #expect(host.state == .unloaded)
        for _ in 0..<100 where model.unloads == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.unloads == 1)
    }

    @Test func useRestartsTheIdleCountdown() async {
        // The delay dwarfs the gaps between uses, so a stalled scheduler can't let the countdown expire between them.
        let (host, model) = idleHost(.seconds(2))
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        for _ in 0..<4 {
            try? await Task.sleep(for: .milliseconds(300))
            _ = await host.run(SmartCleanupRequest(text: "keep going", level: .light))
        }
        // The delay is not over since the first use, but the last use was moments ago.
        if case .ready = host.state {} else { Issue.record("unloaded despite use: \(host.state)") }
        #expect(model.unloads == 0)
        await settle(host) { $0 == .unloaded }
        #expect(host.state == .unloaded)
    }

    @Test func keyDownReloadsAnIdleUnloadedModel() async {
        let (host, model) = idleHost(.milliseconds(100))
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        await settle(host) { $0 == .unloaded }
        host.recordingStarted()
        await settle(host) { if case .ready = $0 { true } else { false } }
        #expect(model.loads == 2)
        if case .ready = host.state {} else { Issue.record("not reloaded: \(host.state)") }
    }

    @Test func aGenerationInFlightIsNeverUnloadedUnderneath() async {
        let gate = DownloadGate()
        let (host, model) = idleHost(.milliseconds(100))
        host.start()
        await settle(host) { if case .ready = $0 { true } else { false } }
        model.cleanGate = gate
        let request = SmartCleanupRequest(text: "long take", level: .light)
        let running = Task { await host.run(request) }
        // Wait until the generation has actually started, then well past the 100 ms idle delay.
        for _ in 0..<500 where model.cleanCalls == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(model.cleanCalls == 1)
        try? await Task.sleep(for: .milliseconds(500))
        if case .ready = host.state {} else { Issue.record("unloaded mid-generation: \(host.state)") }
        #expect(model.unloads == 0)
        await gate.release()
        _ = await running.value
        await settle(host) { $0 == .unloaded }
        #expect(host.state == .unloaded)
    }

    @Test func aWaitingCallerIsReleasedWhenItsTaskIsCancelled() async {
        let gate = DownloadGate()
        let (host, _, _) = host(downloaded: true) { $0.loadGate = gate }
        host.start()
        let waiter = Task { await host.readiness(waitingUpTo: .seconds(60)) }
        try? await Task.sleep(for: .milliseconds(30))
        waiter.cancel()
        #expect(await waiter.value == nil)
        await gate.release()
    }

    @Test func everyWaiterIsReleasedByOneLoad() async {
        let gate = DownloadGate()
        let (host, _, _) = host(downloaded: true) { $0.loadGate = gate }
        host.start()
        let waiters = (0..<3).map { _ in Task { await host.readiness(waitingUpTo: .seconds(60)) } }
        try? await Task.sleep(for: .milliseconds(30))
        await gate.release()
        for waiter in waiters { #expect(await waiter.value != nil) }
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
        let download = item(menu, prefix: "Download Cleanup Model")
        #expect(download?.title == "Download Cleanup Model\u{2026} (1.4 GB)" && download?.isHidden == false)
        #expect(item(menu, prefix: "Cleanup model isn't ready")?.isHidden == false)
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
        #expect(item(menu, prefix: "Download Cleanup Model")?.isHidden == true)
        #expect(item(menu, prefix: "Cleanup model isn't ready")?.isHidden == true)
    }

    @Test func theFallbackLineOnlyShowsForLevelsThatNeedTheModel() {
        let (section, _, _, menu) = make(downloaded: false, level: .basic)
        #expect(item(menu, prefix: "Cleanup model isn't ready")?.isHidden == true)
        withExtendedLifetime(section) {}
    }

    @Test func choosingDownloadAsksFirstAndDeclineFetchesNothing() {
        var asked: [Int] = []
        let (section, host, model, menu) = make(downloaded: false) { asked.append($0); return false }
        let download = item(menu, prefix: "Download Cleanup Model")!
        _ = download.target?.perform(download.action, with: download)
        #expect(asked == [1447] && host.state == .absent && model.downloads == 0)
        withExtendedLifetime(section) {}
    }

    @Test func confirmingStartsTheDownload() async {
        let (section, host, model, menu) = make(downloaded: false, level: .basic)
        let download = item(menu, prefix: "Download Cleanup Model")!
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
