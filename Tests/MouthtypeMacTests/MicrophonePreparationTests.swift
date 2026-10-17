import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct MicrophonePreparationTests {
    private func waitFor(_ count: Int, _ gate: PreparationGate) async throws {
        for _ in 0..<1000 {
            if gate.calls == count { return }
            await Task.yield()
        }
        try #require(gate.calls == count)
    }

    @Test func oldSuccessCannotMarkANewChoiceReady() async throws {
        let state = MicrophonePreparation(), gate = PreparationGate()
        let task = Task { try await state.prepare { try await gate.next() } }
        try await waitFor(1, gate)
        state.invalidate()
        gate.complete(.success(true))
        try await waitFor(2, gate)
        #expect(!state.isPrepared)
        gate.complete(.success(true))
        #expect(try await task.value)
        #expect(state.isPrepared)
    }

    @Test func staleFailureIsIgnoredButNewestFailureRemainsActionable() async throws {
        let state = MicrophonePreparation(), gate = PreparationGate()
        let task = Task { try await state.prepare { try await gate.next() } }
        try await waitFor(1, gate)
        state.invalidate()
        gate.complete(.failure(CaptureError.noInputDevice))
        try await waitFor(2, gate)
        gate.complete(.failure(CaptureError.selectedMicrophoneUnavailable))
        await #expect(throws: CaptureError.self) { try await task.value }
        #expect(!state.isPrepared)
    }

    @Test func rapidChangesHaveABoundedReprepareAndStayUnready() async throws {
        let state = MicrophonePreparation(), gate = PreparationGate()
        let task = Task { try await state.prepare { try await gate.next() } }
        try await waitFor(1, gate)
        state.invalidate()
        gate.complete(.success(true))
        try await waitFor(2, gate)
        state.invalidate()
        gate.complete(.success(true))
        #expect(try await !task.value)
        #expect(!state.isPrepared)
        #expect(gate.calls == 2)
    }

    @Test func skippedActivePreparationAndDuplicateRequestsDoNotClaimReadiness() async throws {
        let state = MicrophonePreparation(), gate = PreparationGate()
        let task = Task { try await state.prepare { try await gate.next() } }
        try await waitFor(1, gate)
        #expect(try await !state.prepare { Issue.record("must coalesce duplicate request"); return true })
        gate.complete(.success(false))
        #expect(try await !task.value)
        #expect(!state.isPrepared)
    }
}

@MainActor private final class PreparationGate {
    private(set) var calls = 0
    private var pending: CheckedContinuation<Bool, any Error>?
    func next() async throws -> Bool {
        calls += 1
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func complete(_ result: Result<Bool, any Error>) {
        let current = pending
        pending = nil
        current?.resume(with: result)
    }
}
