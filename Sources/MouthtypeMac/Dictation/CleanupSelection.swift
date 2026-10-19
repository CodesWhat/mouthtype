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
    /// The level each take is holding a model for, from its recording start until its cleanup ends.
    private var holds: [String: CleanupLevel] = [:]

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

    func unloadThoroughForMemoryPressure() { thorough.unloadForMemoryPressure() }
    func start() { fast.start(); thorough.start() }
    func levelChanged() { fast.levelChanged(); thorough.levelChanged() }
    func startDownload() { selected.startDownload() }
    func cancelDownload() { selected.cancelDownload() }
    nonisolated func recordingStarted() { Task { @MainActor in self.selected.recordingStarted() } }

    /// A rule can ask for a model level while the global one is Off or Basic. Hold demand for that model for the
    /// take, from recording start until `releasePrewarm(for:)`, or the host unloads it the moment its load finishes.
    /// A second call for the same take (the website rule resolving) replaces its hold rather than adding one.
    nonisolated func recordingStarted(level: CleanupLevel, take: String) {
        Task { @MainActor in
            let previous = self.holds.removeValue(forKey: take)
            if let previous { self.adjust(previous, by: -1) }
            guard level.needsModel else {
                if let previous, previous != level { self.host(for: previous).demandDropped() }
                self.selected.recordingStarted()
                return
            }
            self.holds[take] = level
            self.adjust(level, by: 1)
            self.host(for: level).levelChanged()
            if let previous, previous != level { self.host(for: previous).demandDropped() }
        }
    }

    /// The take's cleanup finished or the take ended another way. Drops its demand and unloads the model only when
    /// nothing else wants it; it never loads one, so a model memory pressure unloaded stays unloaded.
    nonisolated func releasePrewarm(for take: String) {
        Task { @MainActor in
            guard let level = self.holds.removeValue(forKey: take) else { return }
            self.adjust(level, by: -1)
            self.host(for: level).demandDropped()
        }
    }

    private func adjust(_ level: CleanupLevel, by delta: Int) {
        if level == .light { demand.fastRequests += delta } else { demand.thoroughRequests += delta }
    }

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
