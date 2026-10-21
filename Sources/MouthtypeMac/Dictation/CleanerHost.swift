import Foundation
import MouthtypeCore
import Observation

/// What the host needs from the local model. `MLXCleaner` is the real one; tests use a fake.
protocol SmartModel: TextCleaner {
    var isDownloaded: Bool { get }
    var revision: String? { get }
    var downloadSizeMB: Int { get }
    func download(progress: @escaping @Sendable (Double) -> Void) async throws
    func load() async throws
    func unload() async
}

extension MLXCleaner: SmartModel {
    nonisolated var downloadSizeMB: Int { spec.downloadSizeMB }
}

/// What the dictation pipeline asks of the model pass, so tests can stand in for the host.
protocol SmartCleaning: Sendable {
    /// The model once it can generate, waiting up to `limit` for a load in progress. Nil when it can't be used.
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo?
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult
    /// A recording began: load the model now so the first cleanup doesn't wait for it.
    func recordingStarted()
    /// The same, for a take whose rules resolve to `level` rather than the global one. The model stays demanded until
    /// `releasePrewarm(for:)`, and a second call for the same take replaces the level.
    func recordingStarted(level: CleanupLevel, take: String)
    /// The take's cleanup finished, or the take was cancelled, discarded or failed. Safe to call more than once.
    func releasePrewarm(for take: String)
    func runReady(_ request: SmartCleanupRequest, waitingUpTo limit: Duration) async -> ReadyCleanup?
}

struct ReadyCleanup: Sendable {
    var model: SmartCleanerInfo
    var result: SmartCleanupResult
}

extension SmartCleaning {
    func recordingStarted(level: CleanupLevel, take: String) { recordingStarted() }
    func releasePrewarm(for take: String) {}

    func runReady(_ request: SmartCleanupRequest, waitingUpTo limit: Duration) async -> ReadyCleanup? {
        guard let model = await readiness(waitingUpTo: limit) else { return nil }
        return ReadyCleanup(model: model, result: await run(request))
    }
}

@MainActor
protocol CleanupModelManaging: SmartCleaning {
    var state: CleanerState { get }
    var modelName: String { get }
    var downloadSizeMB: Int { get }
    var downloadTarget: any CleanupModelManaging { get }
    func start()
    func levelChanged()
    func startDownload()
    func cancelDownload()
}

extension CleanupModelManaging {
    var downloadTarget: any CleanupModelManaging { self }
}

extension UserDefaults {
    /// The stored cleanup level, exposed so changes made outside the app can be observed.
    @objc dynamic var cleanupLevel: String? { string(forKey: CleanupSettings.Key.level) }
}

enum CleanerState: Equatable, Sendable {
    /// Not on disk. Nothing is fetched until the user asks.
    case absent
    case downloading(fraction: Double)
    case loading
    /// On disk, not in memory: the level doesn't need it, or memory pressure unloaded it.
    case unloaded
    case ready(loadSeconds: Double)
    case failed(message: String)
}

/// Owns the local cleanup model like `EngineHost` owns the speech engine: download on request, load when the level
/// needs it, warm it, drop it when the level doesn't or memory is short. State is published for the menu.
@MainActor
@Observable
final class CleanerHost: CleanupModelManaging {
    /// How long the model stays in memory with no cleanup use before its GPU memory is handed back.
    static let defaultIdleUnloadDelay: Duration = .seconds(10 * 60)

    private(set) var state: CleanerState

    nonisolated let smart: SmartCleanup
    @ObservationIgnored private let model: any SmartModel
    @ObservationIgnored private let level: @MainActor () -> CleanupLevel
    @ObservationIgnored private var loadTask: Task<Void, Never>?
    @ObservationIgnored private var unloadTask: Task<Void, Never>?
    @ObservationIgnored private var downloadTask: Task<Void, Never>?
    @ObservationIgnored private var pressure: (any DispatchSourceMemoryPressure)?
    @ObservationIgnored private var defaultsObserver: NSKeyValueObservation?
    @ObservationIgnored private var idleTask: Task<Void, Never>?
    @ObservationIgnored private var activeUses = 0
    @ObservationIgnored private let idleUnloadDelay: Duration

    init(
        model: any SmartModel, level: @escaping @MainActor () -> CleanupLevel,
        budget: (@Sendable (Int) -> Duration)? = nil,
        idleUnloadDelay: Duration = CleanerHost.defaultIdleUnloadDelay
    ) {
        self.idleUnloadDelay = idleUnloadDelay
        self.model = model
        self.level = level
        smart = SmartCleanup(cleaner: model, budget: budget)
        state = model.isDownloaded ? .unloaded : .absent
    }

    var modelName: String {
        switch model.id {
        case "superwhisper-s1-mini": "S1-mini by Superwhisper"
        case CleanerCatalog.smartCleanupID: CleanerCatalog.smartCleanupName
        default: model.displayName
        }
    }
    var downloadSizeMB: Int { model.downloadSizeMB }

    /// Watches for memory pressure and loads the model if the level wants it and it is on disk.
    func start() {
        if pressure == nil {
            let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
            source.setEventHandler { [weak self] in
                Task { @MainActor in self?.unloadForMemoryPressure() }
            }
            source.resume()
            pressure = source
        }
        if defaultsObserver == nil {
            // The level can change from the menu or from outside (`defaults write`); either way the model follows.
            defaultsObserver = UserDefaults.standard.observe(\.cleanupLevel, options: [.new]) { [weak self] _, _ in
                Task { @MainActor in self?.levelChanged() }
            }
        }
        levelChanged()
    }

    /// The level changed: load for light and medium, give the memory back for off and basic.
    func levelChanged() {
        if level().needsModel {
            if case .failed = state { state = model.isDownloaded ? .unloaded : .absent }
            ensureLoaded()
            // Selection routes a take's key-down and its cleanup here, so asking for the model counts as use.
            if case .ready = state { scheduleIdleUnload() }
        } else {
            unload(reason: "level \(level().rawValue)")
        }
    }

    /// Demand for this model dropped. Unloads it if the level no longer wants it; never loads.
    func demandDropped() {
        if !level().needsModel { unload(reason: "prewarm released") }
    }

    func ensureLoaded() {
        guard state == .unloaded, loadTask == nil else { return }
        guard model.isDownloaded else {
            state = .absent
            return
        }
        state = .loading
        let unloading = unloadTask
        loadTask = Task { [model] in
            await unloading?.value
            let clock = ContinuousClock()
            let start = clock.now
            do {
                try await model.load()
                let loadSeconds = (clock.now - start).seconds
                let warmStart = clock.now
                _ = try? await model.clean("warm up the cleanup model", context: CleanupContext())
                Log.cleaner.info("model \(model.id, privacy: .public) loaded in \(loadSeconds, format: .fixed(precision: 2))s, warm-up \((clock.now - warmStart).seconds, format: .fixed(precision: 3))s")
                await smart.resumeAfterModelLoad()
                finishLoad(.ready(loadSeconds: loadSeconds))
            } catch {
                Log.cleaner.error("model \(model.id, privacy: .public) failed to load: \(error.localizedDescription, privacy: .public)")
                finishLoad(.failed(message: error.localizedDescription))
            }
        }
    }

    private func finishLoad(_ result: CleanerState) {
        loadTask = nil
        state = result
        if case .ready = result { scheduleIdleUnload() }
        // The level may have dropped to basic or off while it loaded.
        if case .ready = result, !level().needsModel { unload(reason: "level \(level().rawValue)") }
    }

    func unloadForMemoryPressure() {
        guard case .ready = state else { return }
        unload(reason: "memory pressure")
    }

    private func unload(reason: String) {
        guard case .ready = state else { return }
        state = .unloaded
        idleTask?.cancel()
        idleTask = nil
        unloadTask = Task { [model, smart] in
            await smart.pauseForModelUnload()
            await model.unload()
            unloadTask = nil
        }
        Log.cleaner.info("model unloaded: \(reason, privacy: .public)")
    }

    // MARK: Idle unload

    /// Restarts the idle countdown. Called when the model becomes ready and on every use of it.
    private func scheduleIdleUnload() {
        idleTask?.cancel()
        guard case .ready = state else { idleTask = nil; return }
        idleTask = Task { [weak self, idleUnloadDelay] in
            try? await Task.sleep(for: idleUnloadDelay)
            guard !Task.isCancelled else { return }
            self?.idleExpired()
        }
    }

    private func idleExpired() {
        idleTask = nil
        guard case .ready = state else { return }
        // A generation in flight is use. Its end restarts the countdown.
        guard activeUses == 0 else { return }
        unload(reason: "idle \(idleUnloadDelay)")
    }

    private func beginUse() {
        activeUses += 1
        idleTask?.cancel()
        idleTask = nil
    }

    private func endUse() {
        activeUses = max(0, activeUses - 1)
        if activeUses == 0 { scheduleIdleUnload() }
    }

    // MARK: Download

    /// Fetches the model from Hugging Face. Runs only when the user asks; a stopped download resumes.
    func startDownload() {
        guard state == .absent || { if case .failed = state { return true } else { return false } }(), downloadTask == nil else { return }
        state = .downloading(fraction: 0)
        downloadTask = Task { [model] in
            do {
                try await model.download { fraction in
                    Task { @MainActor [weak self] in self?.downloadProgress(fraction) }
                }
                downloadTask = nil
                state = .unloaded
                Log.cleaner.info("model \(model.id, privacy: .public) downloaded")
                levelChanged()
            } catch is CancellationError {
                downloadTask = nil
                state = model.isDownloaded ? .unloaded : .absent
            } catch {
                downloadTask = nil
                Log.cleaner.error("model download failed: \(error.localizedDescription, privacy: .public)")
                state = .failed(message: error.localizedDescription)
            }
        }
    }

    func cancelDownload() {
        downloadTask?.cancel()
    }

    private func downloadProgress(_ fraction: Double) {
        guard case .downloading = state else { return }
        state = .downloading(fraction: min(max(fraction, 0), 1))
    }

    // MARK: SmartCleaning

    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? {
        let clock = ContinuousClock()
        let deadline = clock.now + limit
        if state == .unloaded { ensureLoaded() }
        while !Task.isCancelled {
            switch state {
            case .ready:
                return SmartCleanerInfo(id: model.id, revision: model.revision)
            case .loading:
                guard clock.now < deadline else { return nil }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return nil }
            default:
                return nil
            }
        }
        return nil
    }

    nonisolated func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult {
        await beginUse()
        let result = await smart.run(request)
        await endUse()
        return result
    }

    /// Runs one explicit selected-text transform once the model is ready.
    func transform(_ kind: TextTransform, text: String, waitingUpTo limit: Duration) async throws -> String {
        let ready = await readiness(waitingUpTo: limit)
        try Task.checkCancellation()
        guard ready != nil else {
            throw CleanerError.unavailable(reason: "\(modelName) isn't loaded yet. Try again in a moment.")
        }
        // Through SmartCleanup so unload, dictation cleanup and a re-requested transform all wait for this generation.
        beginUse()
        defer { endUse() }
        return try await smart.transform(kind, text: text)
    }

    nonisolated func recordingStarted() {
        Task { @MainActor in
            guard self.level().needsModel else { return }
            self.ensureLoaded()
            // A key-down is use: don't unload under a take that is about to need the model.
            if case .ready = self.state { self.scheduleIdleUnload() }
        }
    }
}
