import Foundation

struct PreviewAudio: Sendable {
    var samples: [Float]
    var capturedSampleCount: Int
}

/// Provisional display work only. There is no insertion or transcript-store dependency.
@MainActor
final class LivePreviewSession {
    typealias Source = @MainActor (Int) async -> PreviewAudio
    typealias Recognize = @Sendable ([Float]) async throws -> String?
    typealias Pause = @Sendable () async throws -> Void

    static let maximumSamples = 128_000
    static let minimumSamples = 32_000
    static let maximumCharacters = 160
    private let pause: Pause
    private var generation = 0
    private var request: Request?
    private var worker: Task<Void, Never>?

    private struct Request {
        var generation: Int
        var source: Source
        var recognize: Recognize
        var update: @MainActor (String) -> Void
    }

    init(pause: @escaping Pause = { try await Task.sleep(for: .seconds(2)) }) {
        self.pause = pause
    }

    func start(source: @escaping Source, recognize: @escaping Recognize, update: @escaping @MainActor (String) -> Void) {
        stop()
        request = Request(generation: generation, source: source, recognize: recognize, update: update)
        launchIfNeeded()
    }

    func stop() {
        generation += 1
        request = nil
        worker?.cancel()
    }

    private func launchIfNeeded() {
        guard worker == nil, let request else { return }
        worker = Task { [weak self] in
            await self?.run(request)
            guard let self else { return }
            self.worker = nil
            if self.request?.generation == request.generation { self.request = nil }
            self.launchIfNeeded()
        }
    }

    private func run(_ current: Request) async {
        var lastSampleCount = 0
        let expiresAt = ContinuousClock.now.advanced(by: .seconds(20 * 60))
        // Bound both elapsed time and attempts, including when a test supplies its own cadence.
        for _ in 0..<600 {
            do {
                try await pause()
                guard !Task.isCancelled, generation == current.generation, ContinuousClock.now < expiresAt else { return }
                let snapshot = await current.source(Self.maximumSamples)
                guard !Task.isCancelled, generation == current.generation, ContinuousClock.now < expiresAt else { return }
                guard snapshot.samples.count >= Self.minimumSamples,
                    snapshot.capturedSampleCount > lastSampleCount
                else { continue }
                lastSampleCount = snapshot.capturedSampleCount
                let samples = Array(snapshot.samples.suffix(Self.maximumSamples))
                let text = try await current.recognize(samples)
                guard !Task.isCancelled, generation == current.generation, ContinuousClock.now < expiresAt else { return }
                guard let text else { continue }
                let visible = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(Self.maximumCharacters))
                current.update(visible)
            } catch {
                // Preview failure never replaces the normal final transcription or its recovery path.
                if generation == current.generation { request = nil }
                return
            }
        }
        if generation == current.generation { request = nil }
    }
}
