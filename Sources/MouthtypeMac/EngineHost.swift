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

    @ObservationIgnored private let engineID: String
    @ObservationIgnored private let makeEngine: @Sendable (String) throws -> any Transcriber
    @ObservationIgnored private var task: Task<Void, Never>?

    public init(
        engineID: String = EngineHost.defaultEngineID,
        makeEngine: @escaping @Sendable (String) throws -> any Transcriber = { try EngineCatalog.make(id: $0) }
    ) {
        self.engineID = engineID
        self.makeEngine = makeEngine
    }

    public func start() {
        guard task == nil else { return }
        task = Task { await load() }
    }

    func load() async {
        state = .loading
        Log.engine.info("engine \(self.engineID, privacy: .public) loading")
        let clock = ContinuousClock()
        do {
            let transcriber = try makeEngine(engineID)
            let loadStart = clock.now
            try await transcriber.prepare()
            let loadSeconds = (clock.now - loadStart).seconds
            Log.engine.info("engine \(self.engineID, privacy: .public) prepared in \(loadSeconds, format: .fixed(precision: 2))s")

            let warmStart = clock.now
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
}

extension Duration {
    var seconds: Double {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}
