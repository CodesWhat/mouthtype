import Foundation
import MouthtypeCore
import Observation

@MainActor
@Observable
private final class CleanupDemand {
    var fastRequests = 0
    var thoroughRequests = 0
    let level: @MainActor () -> CleanupLevel

    init(level: @escaping @MainActor () -> CleanupLevel) { self.level = level }

    func wanted(_ candidate: CleanupLevel) -> CleanupLevel {
        let pending = candidate == .light ? fastRequests : thoroughRequests
        return level() == candidate || pending > 0 ? candidate : .basic
    }
}

@MainActor
final class CleanupSelection: CleanupModelManaging {
    private let fast: CleanerHost
    private let thorough: CleanerHost
    private let demand: CleanupDemand

    init(fast: any SmartModel, thorough: any SmartModel, level: @escaping @MainActor () -> CleanupLevel,
         budget: (@Sendable (Int) -> Duration)? = nil) {
        let demand = CleanupDemand(level: level)
        self.demand = demand
        self.fast = CleanerHost(model: fast, level: { demand.wanted(.light) }, budget: budget)
        self.thorough = CleanerHost(model: thorough, level: { demand.wanted(.medium) }, budget: budget)
    }

    private func host(for level: CleanupLevel) -> CleanerHost { level == .medium ? thorough : fast }
    private var selected: CleanerHost { host(for: demand.level()) }
    var state: CleanerState {
        let fastState = fast.state
        let thoroughState = thorough.state
        return demand.level() == .medium ? thoroughState : fastState
    }
    var modelName: String { selected.modelName }
    var downloadSizeMB: Int { selected.downloadSizeMB }
    var downloadTarget: any CleanupModelManaging { selected }

    func start() { fast.start(); thorough.start() }
    func levelChanged() { fast.levelChanged(); thorough.levelChanged() }
    func startDownload() { selected.startDownload() }
    func cancelDownload() { selected.cancelDownload() }
    nonisolated func recordingStarted() { Task { @MainActor in self.selected.recordingStarted() } }
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? {
        await selected.readiness(waitingUpTo: limit)
    }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult {
        await host(for: request.level).run(request)
    }

    func runReady(_ request: SmartCleanupRequest, waitingUpTo limit: Duration) async -> ReadyCleanup? {
        guard request.level.needsModel else { return nil }
        let host = host(for: request.level)
        if request.level == .light { demand.fastRequests += 1 } else { demand.thoroughRequests += 1 }
        defer {
            if request.level == .light { demand.fastRequests -= 1 } else { demand.thoroughRequests -= 1 }
            levelChanged()
        }
        host.levelChanged()
        return await host.runReady(request, waitingUpTo: limit)
    }
}

/// Explicit selected-text transforms run on the Thorough model. S1-mini only normalizes transcripts.
extension CleanupSelection: SelectionTransforming {
    var transformUnavailableReason: String? { TransformAvailability.reason(for: thorough.state, modelName: thorough.modelName) }

    func transform(_ transform: TextTransform, text: String) async throws -> String {
        if let reason = transformUnavailableReason { throw CleanerError.unavailable(reason: reason) }
        demand.thoroughRequests += 1
        defer {
            demand.thoroughRequests -= 1
            levelChanged()
        }
        thorough.levelChanged()
        return try await thorough.transform(transform, text: text, waitingUpTo: .seconds(60))
    }
}
