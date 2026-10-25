import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private struct StubEngine: Transcriber {
    let id = "parakeet-tdt-v3"
    let displayName = "Stub"
    var failOnPrepare = false
    func prepare() async throws {
        if failOnPrepare { throw EngineError.notPrepared(id: id) }
    }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: "", processingSeconds: 0, engineID: id)
    }
}

private actor RoutedStubEngine: Transcriber {
    nonisolated let id: String
    nonisolated let displayName = "Routed stub"
    var prepares = 0
    init(id: String) { self.id = id }
    func prepare() async throws { prepares += 1 }
    func transcribe(samples: [Float]) async throws -> Transcription {
        Transcription(text: "Test sentence.", processingSeconds: 0, engineID: id)
    }
}

@MainActor
@Suite struct EngineHostTests {
    private func settle(_ host: EngineHost) async {
        for _ in 0..<500 {
            if host.state != .loading { return }
            try? await Task.sleep(for: .milliseconds(2))
        }
        Issue.record("speech preparation did not finish")
    }

    @Test func languageChangesPrepareTheRightEngineAndRetainEarlierTakes() async throws {
        let english = RoutedStubEngine(id: EngineHost.defaultEngineID)
        let whisper = RoutedStubEngine(id: "whisper-large-v3-turbo")
        let host = EngineHost(makeEngine: { $0 == english.id ? english : whisper })
        await host.load()
        host.select(language: .explicit(.japanese))
        #expect(host.state == .loading)
        await settle(host)
        #expect(host.engine?.id == "whisper-large-v3-turbo")
        #expect(host.preparedEngine(for: .english)?.id == EngineHost.defaultEngineID)
        #expect(host.preparedEngine(for: .explicit(.hindi))?.id == "whisper-large-v3-turbo")
        let adapter = HostEngine(host: host)
        #expect(try await adapter.transcribe(samples: [0], language: .english).engineID == EngineHost.defaultEngineID)
        #expect(try await adapter.transcribe(samples: [0], language: .explicit(.tamil)).engineID == "whisper-large-v3-turbo")
        host.select(language: .english)
        await settle(host)
        #expect(host.engine?.id == EngineHost.defaultEngineID)
        #expect(await english.prepares == 1)
        #expect(await whisper.prepares == 1)
    }

    @Test func lateModelProgressCannotReplaceTheNewSelection() async {
        actor DelayedEngine: PreparationReporting {
            nonisolated let id = "whisper-large-v3-turbo"
            nonisolated let displayName = "Delayed"
            let gate: DownloadGate
            var completed = false
            init(gate: DownloadGate) { self.gate = gate }
            func prepare() async throws {}
            func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws {
                await report(.downloading(fraction: 0.25))
                await gate.wait()
                await report(.downloading(fraction: 0.75))
                completed = true
            }
            func transcribe(samples: [Float]) async throws -> Transcription {
                Transcription(text: "", processingSeconds: 0, engineID: id)
            }
        }
        let gate = DownloadGate()
        let english = RoutedStubEngine(id: EngineHost.defaultEngineID)
        let delayed = DelayedEngine(gate: gate)
        let host = EngineHost(makeEngine: { id in
            if id == english.id { return english }
            return delayed
        })
        await host.load()
        host.select(language: .explicit(.hindi))
        for _ in 0..<200 where host.downloadProgress?.fraction != 0.25 { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(host.downloadProgress?.fraction == 0.25)
        host.select(language: .english)
        await settle(host)
        await gate.release()
        for _ in 0..<200 where !(await delayed.completed) { await Task.yield() }
        #expect(host.engine?.id == EngineHost.defaultEngineID)
        #expect({ if case .ready(engineID: EngineHost.defaultEngineID, _) = host.state { true } else { false } }())
        #expect(host.downloadProgress == nil)
    }

    @Test func anAlreadyPreparedWhisperCanHandleAnEnglishCaller() async throws {
        let whisper = RoutedStubEngine(id: WhisperEngine.turboID)
        let host = EngineHost(engineID: WhisperEngine.turboID, makeEngine: { _ in whisper })
        await host.load()
        let adapter = HostEngine(host: host)
        #expect(try await adapter.transcribe(samples: [0]).engineID == WhisperEngine.turboID)
        #expect(try await adapter.transcribe(samples: [0], language: .explicit(.german)).engineID == WhisperEngine.turboID)
    }

    @Test func modelDownloadProgressIsVisibleUntilPreparationFinishes() async {
        actor ProgressEngine: PreparationReporting {
            nonisolated let id = "parakeet-tdt-v3"
            nonisolated let displayName = "Progress"
            let gate: DownloadGate
            init(gate: DownloadGate) { self.gate = gate }
            func prepare() async throws {}
            func prepare(report: @escaping @Sendable (EnginePreparation) async -> Void) async throws {
                await report(.downloading(fraction: 0.25))
                await gate.wait()
                await report(.loadingModel)
            }
            func transcribe(samples: [Float]) async throws -> Transcription {
                Transcription(text: "", processingSeconds: 0, engineID: id)
            }
        }
        let gate = DownloadGate()
        let engine = ProgressEngine(gate: gate)
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        for _ in 0..<200 where !host.statusText.contains("25%") { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(host.statusText == "Downloading speech model: 25%")
        await gate.release()
        for _ in 0..<200 {
            if case .ready = host.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(host.statusText == "Parakeet TDT 0.6B v3 ready")
    }

    @Test func startCanRetryAFailedLoadWithoutRestarting() async {
        actor RetryEngine: Transcriber {
            nonisolated let id = "parakeet-tdt-v3"
            nonisolated let displayName = "Retry"
            var attempts = 0
            func prepare() async throws {
                attempts += 1
                if attempts == 1 { throw CocoaError(.fileReadUnknown) }
            }
            func transcribe(samples: [Float]) async throws -> Transcription {
                Transcription(text: "", processingSeconds: 0, engineID: id)
            }
        }
        let engine = RetryEngine()
        let host = EngineHost(makeEngine: { _ in engine })
        host.start()
        for _ in 0..<200 {
            if case .failed = host.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect({ if case .failed = host.state { true } else { false } }())
        host.start()
        for _ in 0..<200 {
            if case .ready = host.state { break }
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect({ if case .ready = host.state { true } else { false } }())
        #expect(await engine.attempts == 2)
    }

    @Test func startsLoading() {
        let host = EngineHost(makeEngine: { _ in StubEngine() })
        #expect(host.state == .loading)
        #expect(host.state.statusText == "Loading model\u{2026}")
    }

    @Test func becomesReadyAfterPrepareAndWarmUp() async {
        let host = EngineHost(makeEngine: { _ in StubEngine() })
        await host.load()
        guard case let .ready(engineID, loadSeconds) = host.state else {
            Issue.record("expected ready, got \(host.state)")
            return
        }
        #expect(engineID == "parakeet-tdt-v3")
        #expect(loadSeconds >= 0)
        #expect(host.state.statusText == "Parakeet TDT 0.6B v3 ready")
    }

    @Test func prepareFailureReportsFailed() async {
        let host = EngineHost(makeEngine: { _ in StubEngine(failOnPrepare: true) })
        await host.load()
        guard case let .failed(message) = host.state else {
            Issue.record("expected failed, got \(host.state)")
            return
        }
        #expect(host.state.statusText == "Engine failed: \(message)")
    }

    @Test func unknownEngineReportsFailed() async {
        let host = EngineHost(engineID: "nope")
        await host.load()
        if case .failed = host.state {} else { Issue.record("expected failed, got \(host.state)") }
    }
}
