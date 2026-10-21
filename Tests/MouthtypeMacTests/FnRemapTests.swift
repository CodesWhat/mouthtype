import Foundation
import Synchronization
import FnRemapKit
import Testing
@testable import MouthtypeMac

private final class FakeStore: KeyMappingStore {
    var mapping: [FnRemapMapping.Entry]?
    var refuseWrites = false
    var unreadable = false
    private(set) var writes: [[FnRemapMapping.Entry]] = []

    init(_ mapping: [FnRemapMapping.Entry]?) { self.mapping = mapping }

    func read() throws -> [FnRemapMapping.Entry]? {
        if unreadable { throw KeyMappingError.unsupportedShape }
        return mapping
    }

    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool {
        guard !refuseWrites else { return false }
        writes.append(mapping)
        self.mapping = mapping
        return true
    }
}

@MainActor
@Suite(.serialized) final class FnRemapTests {
    // One fixed domain, cleared per test, so runs leave at most one plist behind.
    private let suiteName = "FnRemapTests"

    private func makeDefaults() -> UserDefaults {
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    private let capsToEscape: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 0x7_0000_0039, FnRemapMapping.dstKey: 0x7_0000_0029]

    @Test func applyThenRestoreLeavesAnUnsetMappingEmpty() {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        #expect(remap.apply() == .applied)
        #expect(store.mapping == [FnRemapMapping.entry()])
        #expect(remap.isApplied)
        #expect(remap.restore() == .restored)
        #expect(store.mapping ?? [] == [])
        #expect(!remap.isApplied)
    }

    @Test func applyMergesWithAndRestoreReturnsTheUsersMapping() {
        let store = FakeStore([capsToEscape])
        let remap = FnRemap(store: store, defaults: makeDefaults())
        #expect(remap.apply() == .applied)
        #expect(store.mapping == [capsToEscape, FnRemapMapping.entry()])
        #expect(remap.restore() == .restored)
        #expect(store.mapping == [capsToEscape])
    }

    @Test func applyTwiceDoesNotWriteTwice() {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        #expect(remap.apply() == .applied)
        #expect(remap.apply() == .alreadyApplied)
        #expect(store.writes.count == 1)
    }

    @Test func aRefusedWriteLeavesNoMarker() {
        let store = FakeStore([capsToEscape])
        store.refuseWrites = true
        let remap = FnRemap(store: store, defaults: makeDefaults())
        guard case .failed = remap.apply() else { Issue.record("expected failure"); return }
        #expect(!remap.isApplied)
        #expect(store.mapping == [capsToEscape])
    }

    @Test func anUnreadableMappingIsNeverTouched() {
        let store = FakeStore([capsToEscape])
        store.unreadable = true
        let remap = FnRemap(store: store, defaults: makeDefaults())
        guard case .failed = remap.apply() else { Issue.record("expected failure"); return }
        #expect(store.writes.isEmpty)
        #expect(!remap.isApplied)
    }

    @Test func aStaleMarkerFromADeadRunIsUndoneAtNextLaunch() {
        let defaults = makeDefaults()
        let store = FakeStore([capsToEscape])
        let dead = FnRemap(store: store, defaults: defaults)
        #expect(dead.apply() == .applied)
        // The process dies here. A fresh FnRemap over the same defaults is the next launch.
        let next = FnRemap(store: store, defaults: defaults)
        #expect(next.restoreIfStale() == .restored)
        #expect(store.mapping == [capsToEscape])
        #expect(next.restoreIfStale() == .clean)
    }

    @Test func restoreKeepsMappingsAddedWhileApplied() {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        _ = remap.apply()
        store.mapping = (store.mapping ?? []) + [capsToEscape]
        #expect(remap.restore() == .restored)
        #expect(store.mapping == [capsToEscape])
    }

    @Test func restoreWithNothingAppliedDoesNothing() {
        let store = FakeStore([capsToEscape])
        let remap = FnRemap(store: store, defaults: makeDefaults())
        #expect(remap.restore() == .clean)
        #expect(store.writes.isEmpty)
    }

    @Test func signalRoutesIntoTheQuitPathWithoutRestoringOrExiting() {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        var exits: [Int32] = []
        remap.exitProcess = { exits.append($0) }
        remap.hardExit = { _ in }
        _ = remap.apply()
        var requests = 0
        remap.handleSignal(requestTermination: { requests += 1 }, fallbackDelay: 60)
        #expect(requests == 1)
        #expect(exits.isEmpty && remap.isApplied)
    }

    @Test func aSecondSignalRestoresAndExitsAtOnce() {
        let store = FakeStore([capsToEscape])
        let remap = FnRemap(store: store, defaults: makeDefaults())
        var exits: [Int32] = []
        remap.exitProcess = { exits.append($0) }
        remap.hardExit = { _ in }
        _ = remap.apply()
        remap.handleSignal(requestTermination: {}, fallbackDelay: 60)
        remap.handleSignal(requestTermination: {}, fallbackDelay: 60)
        #expect(exits == [0] && !remap.isApplied)
        #expect(store.mapping == [capsToEscape])
    }

    @Test func withoutARequestTheSignalRestoresThenExits() {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        var exits: [Int32] = []
        remap.exitProcess = { exits.append($0) }
        remap.hardExit = { _ in }
        _ = remap.apply()
        remap.handleSignal(requestTermination: nil, fallbackDelay: 60)
        #expect(exits == [0] && !remap.isApplied)
    }

    @Test func aStalledQuitFallsBackToRestoreAndExit() async {
        let store = FakeStore(nil)
        let remap = FnRemap(store: store, defaults: makeDefaults())
        var exits: [Int32] = []
        remap.exitProcess = { exits.append($0) }
        remap.hardExit = { _ in }
        _ = remap.apply()
        remap.handleSignal(requestTermination: {}, fallbackDelay: 0.05)
        for _ in 0..<200 where exits.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(exits.first == 0 && !remap.isApplied)
    }

    @Test func aRealSignalReachesTheQuitRequestOnTheMainQueue() async {
        let remap = FnRemap(store: FakeStore(nil), defaults: makeDefaults())
        var requests = 0
        remap.exitProcess = { _ in }
        remap.hardExit = { _ in }
        remap.installSignalHandlers(signals: [SIGUSR2], requestTermination: { requests += 1 }, fallbackDelay: 60)
        kill(getpid(), SIGUSR2)
        for _ in 0..<200 where requests == 0 { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(requests == 1)
    }

    @Test func theHardExitFiresWhileAModalBlocksTheMainThread() {
        let remap = FnRemap(store: FakeStore(nil), defaults: makeDefaults())
        let hard = Mutex(false)
        remap.exitProcess = { _ in }
        remap.hardExit = { _ in hard.withLock { $0 = true } }
        // Stands in for NSApp.terminate sitting in an NSAlert.runModal that never returns in time.
        remap.handleSignal(requestTermination: { Thread.sleep(forTimeInterval: 0.6) }, fallbackDelay: 0.05, hardGrace: 0.05)
        #expect(hard.withLock { $0 })
    }

    @Test func theHardExitRestoresTheMappingItselfWithoutTheGuard() {
        let store = FakeStore([capsToEscape])
        let remap = FnRemap(store: store, defaults: makeDefaults())
        _ = remap.apply()
        nonisolated(unsafe) let unsafeStore = store
        let restoredAtExit = Mutex<[FnRemapMapping.Entry]?>(nil)
        remap.exitProcess = { _ in }
        remap.hardExit = { _ in restoredAtExit.withLock { $0 = unsafeStore.mapping } }
        remap.handleSignal(requestTermination: { Thread.sleep(forTimeInterval: 0.6) }, fallbackDelay: 0.05, hardGrace: 0.05)
        #expect(restoredAtExit.withLock { $0 } == [capsToEscape])
    }
}
