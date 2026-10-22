import Testing
@testable import MouthtypeCore

private actor InferenceLatch {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var permits = 0
    private(set) var arrivals = 0
    func wait() async {
        arrivals += 1
        if permits > 0 { permits -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        if waiters.isEmpty { permits += 1 } else { waiters.removeFirst().resume() }
    }
}

private actor InferenceProbe {
    private(set) var events: [String] = []
    private var active = 0
    private(set) var maximumActive = 0
    func enter(_ name: String) {
        active += 1
        maximumActive = max(maximumActive, active)
        events.append("\(name).start")
    }
    func leave(_ name: String) { events.append("\(name).end"); active -= 1 }
}

private enum InferenceFailure: Error { case failed }

@Suite struct ParakeetInferenceGateTests {
    private func until(_ condition: () async -> Bool) async {
        for _ in 0..<4_000 {
            if await condition() { return }
            await Task.yield()
        }
    }

    @Test func alreadyActivePreviewFinishesBeforeFinalAndNewPreviewIsDropped() async throws {
        let access = ParakeetInferenceGate()
        let hold = InferenceLatch()
        let probe = InferenceProbe()
        let preview = Task {
            try await access.withPreview(
                prepare: { 1 },
                predict: { _ in
                    await probe.enter("preview")
                    await hold.wait()
                    await probe.leave("preview")
                    return "provisional"
                })
        }
        await until { await hold.arrivals == 1 }
        let final = Task {
            try await access.withFinal {
                await probe.enter("final")
                await probe.leave("final")
                return "final transcript"
            }
        }
        await until {
            if await access.queuedFinalCount == 1 { return true }
            return await probe.events.contains("final.start")
        }
        #expect(await access.queuedFinalCount == 1)
        #expect(!(await probe.events.contains("final.start")))
        let skipped = try await access.withPreview(prepare: { 2 }, predict: { _ in "must be dropped" })
        #expect(skipped == nil)
        await hold.release()
        #expect(try await preview.value == "provisional")
        #expect(try await final.value == "final transcript")
        #expect(await probe.maximumActive == 1)
        #expect(await probe.events == ["preview.start", "preview.end", "final.start", "final.end"])
    }

    @Test func queuedFinalsKeepOrderAndReserveAdmissionDuringHandoff() async throws {
        let access = ParakeetInferenceGate()
        let previewHold = InferenceLatch()
        let finalHold = InferenceLatch()
        let probe = InferenceProbe()
        let preview = Task {
            try await access.withPreview(
                prepare: { true },
                predict: { _ in
                    await previewHold.wait()
                    return "preview"
                })
        }
        await until { await previewHold.arrivals == 1 }
        let first = Task {
            try await access.withFinal {
                await probe.enter("first")
                await finalHold.wait()
                await probe.leave("first")
                return 1
            }
        }
        await until {
            if await access.queuedFinalCount == 1 { return true }
            return await probe.events.contains("first.start")
        }
        let second = Task {
            try await access.withFinal {
                await probe.enter("second")
                await probe.leave("second")
                return 2
            }
        }
        await until {
            if await access.queuedFinalCount == 2 { return true }
            return await probe.events.contains("second.start")
        }
        #expect(await access.queuedFinalCount == 2)
        await previewHold.release()
        _ = try await preview.value
        await until { await probe.events.contains("first.start") }
        #expect(!(await probe.events.contains("second.start")))
        #expect(try await access.withPreview(prepare: { true }, predict: { _ in "barged" }) == nil)
        await finalHold.release()
        #expect(try await first.value == 1)
        #expect(try await second.value == 2)
        #expect(await probe.maximumActive == 1)
        #expect(await probe.events == ["first.start", "first.end", "second.start", "second.end"])
    }

    @Test func cancelDuringPreparationPreventsLatePredictionAndReleasesAccess() async throws {
        let access = ParakeetInferenceGate()
        let setup = InferenceLatch()
        let probe = InferenceProbe()
        let preview = Task {
            try await access.withPreview(
                prepare: {
                    await setup.wait()
                    return "prepared"
                },
                predict: { _ in
                    await probe.enter("late prediction")
                    await probe.leave("late prediction")
                    return "must not appear"
                })
        }
        await until { await setup.arrivals == 1 }
        preview.cancel()
        await setup.release()
        await #expect(throws: CancellationError.self) { try await preview.value }
        #expect(await probe.events.isEmpty)
        #expect(try await access.withFinal { "after cancellation" } == "after cancellation")
    }

    @Test func canceledQueuedFinalDoesNotPredictOrBlockTheFollowingFinal() async throws {
        let access = ParakeetInferenceGate()
        let hold = InferenceLatch()
        let probe = InferenceProbe()
        let preview = Task {
            try await access.withPreview(
                prepare: { true },
                predict: { _ in
                    await hold.wait()
                    return "preview"
                })
        }
        await until { await hold.arrivals == 1 }
        let cancelled = Task {
            try await access.withFinal {
                await probe.enter("cancelled final")
                return "must not run"
            }
        }
        await until {
            if await access.queuedFinalCount == 1 { return true }
            return await probe.events.contains("cancelled final.start")
        }
        cancelled.cancel()
        let following = Task { try await access.withFinal { "following final" } }
        await hold.release()
        _ = try await preview.value
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(try await following.value == "following final")
        #expect(await probe.events.isEmpty)
    }

    @Test func setupAndPredictionFailuresReleaseTheLease() async throws {
        let access = ParakeetInferenceGate()
        await #expect(throws: InferenceFailure.self) {
            try await access.withPreview(prepare: { throw InferenceFailure.failed }, predict: { (_: Int) in "unreachable" })
        }
        await #expect(throws: InferenceFailure.self) {
            try await access.withPreview(prepare: { 1 }, predict: { _ in throw InferenceFailure.failed })
        }
        await #expect(throws: InferenceFailure.self) {
            try await access.withFinal { throw InferenceFailure.failed }
        }
        #expect(try await access.withPreview(prepare: { 1 }, predict: { _ in "recovered" }) == "recovered")
        #expect(try await access.withFinal { "unchanged final" } == "unchanged final")
    }
}
