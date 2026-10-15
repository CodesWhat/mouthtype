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
    private var warmingUp = false

    public var statusText: String {
        guard state == .loading else { return state.statusText }
        if warmingUp { return "Warming up speech model…" }
        switch preparation {
        case let .downloading(fraction):
            return "Downloading speech model: \(Int((min(max(fraction, 0), 1) * 100).rounded()))%"
        case .compiling: return "Preparing downloaded speech model…"
        case .loadingModel: return state.statusText
        }
    }

    @ObservationIgnored private let engineID: String
    @ObservationIgnored private let makeEngine: @Sendable (String) throws -> any Transcriber
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        engineID: String = EngineHost.defaultEngineID,
        makeEngine: @escaping @Sendable (String) throws -> any Transcriber = { try EngineCatalog.make(id: $0, englishHint: true) }
    ) {
        self.engineID = engineID
        self.makeEngine = makeEngine
    }

    public func start() {
        guard task == nil else { return }
        if case .ready = state { return }
        state = .loading
        task = Task {
            await load()
            task = nil
        }
    }

    func load() async {
        state = .loading
        preparation = .loadingModel
        warmingUp = false
        Log.engine.info("engine \(self.engineID, privacy: .public) loading")
        let clock = ContinuousClock()
        do {
            let transcriber = try makeEngine(engineID)
            let loadStart = clock.now
            if let reporting = transcriber as? any PreparationReporting {
                try await reporting.prepare { [weak self] stage in await self?.report(stage) }
            } else {
                try await transcriber.prepare()
            }
            let loadSeconds = (clock.now - loadStart).seconds
            Log.engine.info("engine \(self.engineID, privacy: .public) prepared in \(loadSeconds, format: .fixed(precision: 2))s")

            let warmStart = clock.now
            warmingUp = true
            _ = try await transcriber.transcribe(samples: [Float](repeating: 0, count: 16_000))
            let warmSeconds = (clock.now - warmStart).seconds
            Log.engine.info("engine \(self.engineID, privacy: .public) warm-up in \(warmSeconds, format: .fixed(precision: 2))s")

            engine = transcriber
            state = .ready(engineID: engineID, loadSeconds: loadSeconds)
            Log.engine.info("engine \(self.engineID, privacy: .public) ready, load \(loadSeconds, format: .fixed(precision: 2))s")
        } catch {
            state = .failed(message: error.localizedDescription)
            Log.engine.error("engine \(self.engineID, privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func report(_ stage: EnginePreparation) {
        guard state == .loading, !warmingUp else { return }
        preparation = stage
    }
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
