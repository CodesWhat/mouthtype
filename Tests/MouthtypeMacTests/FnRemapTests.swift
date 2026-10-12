import Foundation
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

@Suite struct FnRemapMappingTests {
    private let ours = FnRemapMapping.entry()
    private let capsToEscape: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 0x7_0000_0039, FnRemapMapping.dstKey: 0x7_0000_0029]

    @Test func usageValuesAreThePageShiftedLeft32() {
        #expect(FnRemapMapping.fnSource == 0xFF_0000_0003)
        #expect(FnRemapMapping.fnDestination == 0x7_0000_006E)
        #expect(ours == [FnRemapMapping.srcKey: 0xFF_0000_0003, FnRemapMapping.dstKey: 0x7_0000_006E])
    }

    @Test func mergeKeepsTheUsersMapping() {
        #expect(FnRemapMapping.merging(existing: [capsToEscape], ours: ours) == [capsToEscape, ours])
        #expect(FnRemapMapping.merging(existing: [], ours: ours) == [ours])
    }

    @Test func mergeDisplacesAnExistingMappingOfTheSameSource() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0039]
        #expect(FnRemapMapping.merging(existing: [theirFn, capsToEscape], ours: ours) == [capsToEscape, ours])
    }

    @Test func restoreRemovesOnlyOurEntry() {
        #expect(FnRemapMapping.restoring(current: [capsToEscape, ours], ours: ours, original: [capsToEscape]) == [capsToEscape])
        #expect(FnRemapMapping.restoring(current: [ours], ours: ours, original: []) == [])
    }

    @Test func restorePutsBackADisplacedEntryAndKeepsLaterAdditions() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0039]
        let addedLater: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 1, FnRemapMapping.dstKey: 2]
        let restored = FnRemapMapping.restoring(current: [capsToEscape, ours, addedLater], ours: ours, original: [theirFn, capsToEscape])
        #expect(restored == [capsToEscape, addedLater, theirFn])
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
}
