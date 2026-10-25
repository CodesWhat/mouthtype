import Foundation
import MouthtypeCore
import Observation

public enum EngineState: Equatable, Sendable {
    case loading
    case ready(engineID: String, loadSeconds: Double)
    case failed(message: String)

    public var statusText: String {
        switch self {
        case .loading:
            return "Loading model\u{2026}"
        case let .ready(engineID, _):
            let name = EngineCatalog.entries.first { $0.id == engineID }?.displayName ?? engineID
            return "\(name.components(separatedBy: " (")[0]) ready"
        case let .failed(message):
            return "Engine failed: \(message)"
        }
    }
}

@MainActor
@Observable
public final class EngineHost {
    public static let defaultEngineID = "parakeet-tdt-v3"

    public private(set) var state: EngineState = .loading
    public private(set) var engine: (any Transcriber)?
    public private(set) var preparation: EnginePreparation = .loadingModel
    /// Bytes fetched so far, with a smoothed time remaining. Nil until a download reports.
    public private(set) var downloadProgress: ModelDownloadProgress?
    private var warmingUp = false
    /// The model is on disk (cached, or its download finished), so only compiling and loading are left.
    private var downloadSettled = false

    public var statusText: String {
        guard state == .loading else { return state.statusText }
        if warmingUp { return "Warming up speech model…" }
        switch preparation {
        case let .downloading(fraction):
            return "Downloading speech model: \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        case let .progress(progress):
            return "Downloading speech model: \(Int((progress.fraction * 100).rounded()))%"
        case .cached: return state.statusText
        case .compiling: return "Preparing downloaded speech model…"
        case .loadingModel: return state.statusText
        }
    }

    /// What the setup bar shows for the speech model.
    public var downloadStatus: ModelDownloadStatus {
        switch state {
        case .ready: .done
        case let .failed(message): .failed(message: message)
        case .loading:
            if downloadSettled { .done } else if let downloadProgress { .downloading(downloadProgress) } else { .preparing }
        }
    }

    @ObservationIgnored private var rateMeter = DownloadRateMeter()
    @ObservationIgnored private let uptime: () -> TimeInterval
    public private(set) var engineID: String
    // Keep prepared models for earlier takes whose captured language differs from the current setting.
    @ObservationIgnored private var prepared: [String: any Transcriber] = [:]
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private let makeEngine: @Sendable (String) throws -> any Transcriber
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        engineID: String = EngineHost.defaultEngineID,
        makeEngine: @escaping @Sendable (String) throws -> any Transcriber = { try EngineCatalog.make(id: $0) },
        uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.uptime = uptime
        self.engineID = engineID
        self.makeEngine = makeEngine
    }

    func select(language: DictationLanguageRequest) {
        let selectedID = language.speechEngineID
        guard selectedID != engineID else { start(); return }
        generation += 1
        task?.cancel()
        task = nil
        engineID = selectedID
        engine = nil
        state = .loading
        start()
    }

    func preparedEngine(for language: DictationLanguageRequest) -> (any Transcriber)? {
        prepared[language.speechEngineID] ?? prepared[WhisperEngine.turboID]
    }

    var preparedEngines: [any Transcriber] { Array(prepared.values) }

    public func start() {
        guard task == nil else { return }
        if case .ready = state { return }
        state = .loading
        let id = generation
        task = Task {
            guard id == generation, !Task.isCancelled else { return }
            await load()
            if id == generation { task = nil }
        }
    }

    func load() async {
        let engineID = self.engineID
        let loadGeneration = generation
        state = .loading
        preparation = .loadingModel
        downloadProgress = nil
        downloadSettled = false
        rateMeter.reset()
        warmingUp = false
        if let cached = prepared[engineID] {
            engine = cached
            downloadSettled = true
            state = .ready(engineID: engineID, loadSeconds: 0)
            return
        }
        Log.engine.info("engine \(engineID, privacy: .public) loading")
        let clock = ContinuousClock()
        do {
            let transcriber = try makeEngine(engineID)
            let loadStart = clock.now
            if let reporting = transcriber as? any PreparationReporting {
                try await reporting.prepare { [weak self] stage in await self?.report(stage, generation: loadGeneration) }
            } else {
                try await transcriber.prepare()
            }
            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            let loadSeconds = (clock.now - loadStart).seconds
            Log.engine.info("engine \(engineID, privacy: .public) prepared in \(loadSeconds, format: .fixed(precision: 2))s")

            let warmStart = clock.now
            warmingUp = true
            _ = try await transcriber.transcribe(samples: [Float](repeating: 0, count: 16_000))
            let warmSeconds = (clock.now - warmStart).seconds
            Log.engine.info("engine \(engineID, privacy: .public) warm-up in \(warmSeconds, format: .fixed(precision: 2))s")

            try Task.checkCancellation()
            guard loadGeneration == generation else { return }
            prepared[engineID] = transcriber
            engine = transcriber
            state = .ready(engineID: engineID, loadSeconds: loadSeconds)
            Log.engine.info("engine \(engineID, privacy: .public) ready, load \(loadSeconds, format: .fixed(precision: 2))s")
        } catch {
            guard loadGeneration == generation, !Task.isCancelled else { return }
            state = .failed(message: error.localizedDescription)
            Log.engine.error("engine \(engineID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func report(_ stage: EnginePreparation, generation loadGeneration: Int) {
        guard loadGeneration == generation, state == .loading, !warmingUp else { return }
        switch stage {
        case let .progress(progress):
            record(progress)
        case let .downloading(fraction):
            record(ModelDownloadProgress(fraction: fraction))
        case .cached, .compiling, .loadingModel:
            downloadSettled = true
            preparation = stage
        }
    }

    /// Reports are delivered from unordered tasks, so one that arrives behind a later one is dropped rather than moving the bar back.
    private func record(_ progress: ModelDownloadProgress) {
        guard !downloadSettled, progress.fraction >= (downloadProgress?.fraction ?? 0) else { return }
        rateMeter.record(fraction: progress.fraction, at: uptime())
        var update = progress
        update.secondsRemaining = rateMeter.secondsRemaining
        downloadProgress = update
        preparation = .progress(update)
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
