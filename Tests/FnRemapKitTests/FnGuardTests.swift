import FnRemapKit
import Foundation
import Testing

private final class FakeStore: KeyMappingStore {
    var mapping: [FnRemapMapping.Entry]?
    var refuseWrites = false
    private(set) var writes: [[FnRemapMapping.Entry]] = []

    init(_ mapping: [FnRemapMapping.Entry]?) { self.mapping = mapping }

    func read() throws -> [FnRemapMapping.Entry]? { mapping }

    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool {
        guard !refuseWrites else { return false }
        writes.append(mapping)
        self.mapping = mapping
        return true
    }
}

@Suite struct FnGuardArgumentsTests {
    @Test func parsesPidAndBothUsages() {
        let parsed = FnGuardArguments.parse(["guard", "4242", "1095216660483", "0x70000006E"])
        #expect(parsed == FnGuardArguments(parent: 4242, entry: FnRemapMapping.entry()))
    }

    @Test func rejectsWrongCountsAndNonNumbers() {
        #expect(FnGuardArguments.parse(["guard"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "4242", "1"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "4242", "1", "2", "3"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "abc", "1", "2"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "4242", "x", "2"]) == nil)
    }

    @Test func rejectsPidsThatCouldNeverBeTheApp() {
        #expect(FnGuardArguments.parse(["guard", "0", "1", "2"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "1", "1", "2"]) == nil)
        #expect(FnGuardArguments.parse(["guard", "-5", "1", "2"]) == nil)
    }
}

@Suite struct FnGuardRemovalTests {
    private let ours = FnRemapMapping.entry()
    private let capsToEscape: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 0x7_0000_0039, FnRemapMapping.dstKey: 0x7_0000_0029]

    @Test func removesOnlyOurEntryAndKeepsTheUsersOwn() {
        let store = FakeStore([capsToEscape, ours])
        #expect(FnGuard.removeOurs(ours, from: store) == .removed)
        #expect(store.mapping == [capsToEscape])
    }

    @Test func aMappingOfOurSourceToAnotherDestinationIsNotOurs() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0039]
        let store = FakeStore([theirFn])
        #expect(FnGuard.removeOurs(ours, from: store) == .alreadyGone)
        #expect(store.writes.isEmpty)
    }

    @Test func doesNothingWhenTheMappingIsAlreadyGone() {
        for mapping: [FnRemapMapping.Entry]? in [nil, [], [capsToEscape]] {
            let store = FakeStore(mapping)
            #expect(FnGuard.removeOurs(ours, from: store) == .alreadyGone)
            #expect(store.writes.isEmpty)
        }
    }

    @Test func reportsARefusedWrite() {
        let store = FakeStore([ours])
        store.refuseWrites = true
        #expect(FnGuard.removeOurs(ours, from: store) == .failed("the HID system refused the write"))
    }
}

@Suite struct FnGuardWaitTests {
    private func spawn(_ seconds: String) throws -> Process {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sleep")
        process.arguments = [seconds]
        try process.run()
        return process
    }

    @Test func removesTheMappingOnlyAfterTheParentExits() throws {
        let parent = try spawn("0.3")
        let store = FakeStore([FnRemapMapping.entry()])
        let started = ContinuousClock.now
        let outcome = FnGuard.run(FnGuardArguments(parent: parent.processIdentifier, entry: FnRemapMapping.entry()), store: store)
        let waited = ContinuousClock.now - started
        parent.waitUntilExit()
        #expect(outcome == .removed)
        #expect(store.mapping == [])
        #expect(waited >= .milliseconds(200), "returned before the parent exited: \(waited)")
    }

    @Test func aParentThatIsAlreadyGoneIsHandled() throws {
        let parent = try spawn("0")
        parent.waitUntilExit()
        let store = FakeStore([FnRemapMapping.entry()])
        let outcome = FnGuard.run(FnGuardArguments(parent: parent.processIdentifier, entry: FnRemapMapping.entry()), store: store)
        #expect(outcome == .removed)
    }

    @Test func aParentKilledWithSIGKILLCountsAsExited() throws {
        let parent = try spawn("30")
        let store = FakeStore([FnRemapMapping.entry()])
        _ = Task.detached {
            try await Task.sleep(for: .milliseconds(150))
            kill(parent.processIdentifier, SIGKILL)
        }
        let outcome = FnGuard.run(FnGuardArguments(parent: parent.processIdentifier, entry: FnRemapMapping.entry()), store: store)
        parent.waitUntilExit()
        #expect(outcome == .removed)
    }

    @Test func runUsesTheInjectedWait() {
        let store = FakeStore([FnRemapMapping.entry()])
        nonisolated(unsafe) var waitedOn: pid_t?
        let outcome = FnGuard.run(FnGuardArguments(parent: 77, entry: FnRemapMapping.entry()), store: store) { waitedOn = $0 }
        #expect(waitedOn == 77 && outcome == .removed)
    }
}
