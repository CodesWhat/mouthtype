import Testing
@testable import MouthtypeMac

@MainActor @Suite struct AppTerminationTests {
    @Test func repeatedQuitRequestsSharePreservationAndReplyOnlyAfterClipboardSettlement() async throws {
        let termination = AppTermination()
        var events: [String] = []
        var preserved: CheckedContinuation<Bool, Never>?
        var settled: CheckedContinuation<Void, Never>?
        defer { preserved?.resume(returning: false); settled?.resume() }
        let preserve: @MainActor () async -> Bool = {
            events.append("capture")
            return await withCheckedContinuation { preserved = $0 }
        }
        let clipboard: @MainActor () async -> Void = {
            events.append("clipboard")
            await withCheckedContinuation { settled = $0 }
        }
        let reply: @MainActor (Bool) -> Void = { events.append("reply.\($0)") }
        termination.begin(preserve: preserve, settleClipboard: clipboard, reply: reply)
        for _ in 0..<1_000 where preserved == nil { await Task.yield() }
        termination.begin(preserve: preserve, settleClipboard: clipboard, reply: reply)
        #expect(events == ["capture"])
        let first = try #require(preserved); preserved = nil
        first.resume(returning: true)
        for _ in 0..<1_000 where settled == nil { await Task.yield() }
        #expect(events == ["capture", "clipboard"])
        let second = try #require(settled); settled = nil
        second.resume()
        for _ in 0..<1_000 where events.count < 3 { await Task.yield() }
        #expect(events == ["capture", "clipboard", "reply.true"])
    }

    @Test func failedPreservationCancelsQuitWithoutSettlingClipboardAndCanBeRetried() async {
        let termination = AppTermination()
        var canSave = false, saves = 0, settles = 0
        var replies: [Bool] = []
        let preserve: @MainActor () async -> Bool = {
            saves += 1; return canSave
        }
        let settle: @MainActor () async -> Void = { settles += 1 }
        let reply: @MainActor (Bool) -> Void = { replies.append($0) }
        termination.begin(preserve: preserve, settleClipboard: settle, reply: reply)
        for _ in 0..<1_000 where replies.isEmpty { await Task.yield() }
        #expect(replies == [false] && saves == 1 && settles == 0)
        canSave = true
        termination.begin(preserve: preserve, settleClipboard: settle, reply: reply)
        for _ in 0..<1_000 where replies.count < 2 { await Task.yield() }
        #expect(replies == [false, true] && saves == 2 && settles == 1)
    }
}
