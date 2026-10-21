import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// A cleanup model whose download reports what the test scripts, then waits on a gate or fails.
private final class ScriptedModel: SmartModel, @unchecked Sendable {
    let id: String
    let displayName = "Scripted"
    let downloadSizeMB: Int
    var steps: [ModelDownloadProgress] = []
    var failure: Error?
    var gate: DownloadGate?
    private let lock = NSLock()
    private var downloaded: Bool
    private(set) var downloads = 0

    init(id: String, sizeMB: Int, downloaded: Bool = false) {
        self.id = id
        downloadSizeMB = sizeMB
        self.downloaded = downloaded
    }

    var isDownloaded: Bool { lock.withLock { downloaded } }
    var revision: String? { "abc123" }
    func prepare() async throws {}
    func clean(_ transcript: String, context: CleanupContext) async throws -> String { transcript }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws {}

    func downloadReporting(report: @escaping @Sendable (ModelDownloadProgress) -> Void) async throws {
        lock.withLock { downloads += 1 }
        for step in steps { report(step) }
        await gate?.wait()
        if let failure { throw failure }
        lock.withLock { downloaded = true }
    }

    func load() async throws {}
    func unload() async {}
}

private actor ScriptedEngine: PreparationReporting {
    nonisolated let id = "parakeet-tdt-v3"
    nonisolated let displayName = "Scripted"
    let reports: [EnginePreparation]
    let gate: DownloadGate?
    let failure: Error?

    init(reports: [EnginePreparation], gate: DownloadGate? = nil, failure: Error? = nil) {
        self.reports = reports
        self.gate = gate
        self.failure = failure
    }

    func prepare() async throws {}

    func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws {
        for stage in reports { await report(stage) }
        await gate?.wait()
        if let failure { throw failure }
    }

    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: "", processingSeconds: 0, engineID: id)
    }
}

@MainActor
@Suite struct SetupDownloadProgressTests {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<300 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    private func progress(_ fraction: Double) -> EnginePreparation {
        .progress(ModelDownloadProgress(fraction: fraction, knownTotalBytes: 483_000_000))
    }

    // MARK: Speech

    @Test func speechDownloadShowsBytesAndASmoothedTimeRemaining() async {
        let gate = DownloadGate()
        var clock = 0.0
        let engine = ScriptedEngine(reports: [progress(0.1), progress(0.2), progress(0.3)], gate: gate)
        let host = EngineHost(makeEngine: { _ in engine }, uptime: { defer { clock += 2 }; return clock })
        host.start()
        await waitUntil { host.downloadProgress?.fraction == 0.3 }
        guard case let .downloading(shown) = host.downloadStatus else { Issue.record("not downloading: \(host.downloadStatus)"); return }
        #expect(shown.totalBytes == 483_000_000 && shown.completedBytes == 144_900_000)
        // 0.05 per second over the window, 0.7 left.
        #expect(abs((shown.secondsRemaining ?? 0) - 14) < 0.001)
        #expect(ModelDownloadFormat.caption(shown) == "145 of 483 MB, about 15 seconds left")
        await gate.release()
        await waitUntil { if case .ready = host.state { true } else { false } }
        #expect(host.downloadStatus == .done)
    }

    @Test func reportsThatArriveOutOfOrderDoNotMoveTheSpeechBarBack() async {
        let gate = DownloadGate()
        let engine = ScriptedEngine(reports: [progress(0.6), progress(0.2)], gate: gate)
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        await waitUntil { host.downloadProgress != nil }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(host.downloadProgress?.fraction == 0.6)
        await gate.release()
    }

    @Test func aCachedSpeechModelIsDoneImmediately() async {
        let gate = DownloadGate()
        let engine = ScriptedEngine(reports: [.cached], gate: gate)
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        await waitUntil { host.downloadStatus == .done }
        #expect(host.downloadStatus == .done)
        #expect(host.downloadProgress == nil)
        if case .ready = host.state { Issue.record("still held at the gate, so loading hasn't finished") }
        await gate.release()
    }

    @Test func downloadProgressAfterTheModelIsOnDiskIsIgnored() async {
        // FluidAudio fetches the voice detector after the speech model. It must not reopen the bar.
        let gate = DownloadGate()
        let engine = ScriptedEngine(reports: [progress(0.5), .loadingModel, progress(0.1)], gate: gate)
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        await waitUntil { host.downloadStatus == .done }
        try? await Task.sleep(for: .milliseconds(30))
        #expect(host.downloadStatus == .done)
        await gate.release()
    }

    @Test func aFailedSpeechDownloadShowsTheFailureAndRetryStartsOver() async {
        let engine = ScriptedEngine(reports: [progress(0.4)], failure: CocoaError(.fileReadUnknown))
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        await waitUntil { if case .failed = host.state { true } else { false } }
        guard case .failed = host.downloadStatus else { Issue.record("not failed: \(host.downloadStatus)"); return }
        host.start()
        await waitUntil { host.downloadProgress != nil }
        #expect({ if case .failed = host.downloadStatus { false } else { true } }())
    }

    @Test func beforeAnyReportTheSpeechStepHasNothingToShowYet() {
        let host = EngineHost(makeEngine: { _ in ScriptedEngine(reports: []) })
        #expect(host.downloadStatus == .preparing)
    }

    // MARK: Cleanup models

    private func selection(fast: ScriptedModel, thorough: ScriptedModel, level: CleanupLevel = .light) -> CleanupSelection {
        CleanupSelection(fast: fast, thorough: thorough, level: { level })
    }

    @Test func modelsNotOnDiskAreAvailableAndNothingDownloadsOnItsOwn() async {
        let fast = ScriptedModel(id: "superwhisper-s1-mini", sizeMB: 1447)
        let thorough = ScriptedModel(id: "gemma-4-e4b-it-4bit", sizeMB: 5150)
        let selection = selection(fast: fast, thorough: thorough)
        selection.start()
        try? await Task.sleep(for: .milliseconds(50))
        let models = selection.cleanupModels()
        #expect(models.map(\.level) == [.light, .medium])
        #expect(models.map(\.status) == [.available, .available])
        #expect(models.map(\.selected) == [true, false])
        #expect(models.map(\.sizeMB) == [1447, 5150])
        #expect(fast.downloads == 0 && thorough.downloads == 0, "setup never starts a cleanup download without a click")
    }

    @Test func aCleanupDownloadShowsItsOwnProgressAndThenDone() async {
        let gate = DownloadGate()
        let fast = ScriptedModel(id: "superwhisper-s1-mini", sizeMB: 1447)
        fast.steps = [ModelDownloadProgress(hubCompletedUnits: 500_000_000, hubTotalUnits: 1_447_000_000)]
        fast.gate = gate
        let thorough = ScriptedModel(id: "gemma-4-e4b-it-4bit", sizeMB: 5150)
        let selection = selection(fast: fast, thorough: thorough)
        selection.downloadCleanupModel(.light)
        await waitUntil { if case .downloading(let p) = selection.cleanupModels()[0].status { p.completedBytes == 500_000_000 } else { false } }
        guard case let .downloading(p) = selection.cleanupModels()[0].status else { Issue.record("not downloading"); return }
        #expect(p.usesBytes && p.totalBytes == 1_447_000_000)
        #expect(selection.cleanupModels()[1].status == .available, "the other model is untouched")
        await gate.release()
        await waitUntil { selection.cleanupModels()[0].status == .done }
        #expect(selection.cleanupModels()[0].status == .done)
        #expect(thorough.downloads == 0)
    }

    @Test func aFailedCleanupDownloadShowsTheErrorAndCanBeRetried() async {
        let fast = ScriptedModel(id: "superwhisper-s1-mini", sizeMB: 1447)
        fast.failure = CocoaError(.fileWriteOutOfSpace)
        let selection = selection(fast: fast, thorough: ScriptedModel(id: "gemma-4-e4b-it-4bit", sizeMB: 5150))
        selection.downloadCleanupModel(.light)
        await waitUntil { if case .failed = selection.cleanupModels()[0].status { true } else { false } }
        guard case .failed = selection.cleanupModels()[0].status else { Issue.record("not failed"); return }
        fast.failure = nil
        selection.downloadCleanupModel(.light)
        await waitUntil { selection.cleanupModels()[0].status == .done }
        #expect(fast.downloads == 2)
    }

    @Test func aModelAlreadyOnDiskIsDone() {
        let selection = selection(
            fast: ScriptedModel(id: "superwhisper-s1-mini", sizeMB: 1447, downloaded: true),
            thorough: ScriptedModel(id: "gemma-4-e4b-it-4bit", sizeMB: 5150), level: .medium)
        let models = selection.cleanupModels()
        #expect(models.map(\.status) == [.done, .available])
        #expect(models.map(\.selected) == [false, true])
    }

    @Test func aModelWithOnlyAFractionStillGetsASizedBar() async {
        // The default `download(report:)` wraps `download(progress:)`, sized from the catalog.
        let gate = DownloadGate()
        let model = FakeSmartModel(downloaded: false)
        model.downloadGate = gate
        model.progressSteps = [0.5]
        let host = CleanerHost(model: model, level: { .light })
        host.startDownload()
        await waitUntil { host.downloadProgress?.fraction == 0.5 }
        #expect(host.downloadProgress?.totalBytes == 1_447_000_000)
        #expect(host.downloadStatus == .downloading(host.downloadProgress!))
        await gate.release()
        await waitUntil { host.downloadProgress == nil }
        #expect(host.downloadStatus == .done)
    }
}
