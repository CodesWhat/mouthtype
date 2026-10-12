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

@MainActor
@Suite struct EngineHostTests {
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
