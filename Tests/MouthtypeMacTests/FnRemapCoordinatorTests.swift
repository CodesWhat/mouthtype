import Foundation
import Testing
@testable import MouthtypeMac

private final class FakeKeyStore: KeyMappingStore {
    var mapping: [FnRemapMapping.Entry]?
    var refuseWrites = false

    init(_ mapping: [FnRemapMapping.Entry]? = nil) { self.mapping = mapping }

    func read() throws -> [FnRemapMapping.Entry]? { mapping }

    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool {
        guard !refuseWrites else { return false }
        self.mapping = mapping
        return true
    }
}

@MainActor
@Suite(.serialized) struct FnRemapCoordinatorTests {
    private let ours = FnRemapMapping.entry()
    private let remapped = HotkeySource.remapped(keyCode: 80)

    private func make(
        _ store: FakeKeyStore, preferred: Bool? = nil
    ) -> (FnRemapCoordinator, UserDefaults, UserDefaults) {
        let marker = UserDefaults(suiteName: "remap-coordinator-marker-\(UUID().uuidString)")!
        let preferences = UserDefaults(suiteName: "remap-coordinator-prefs-\(UUID().uuidString)")!
        if let preferred { preferences.set(preferred, forKey: FnRemapCoordinator.preferenceKey) }
        let coordinator = FnRemapCoordinator(remap: FnRemap(store: store, defaults: marker), preferences: preferences)
        return (coordinator, marker, preferences)
    }

    @Test func remapIsOnByDefaultAndAppliedAtLaunch() {
        let store = FakeKeyStore()
        let (coordinator, _, _) = make(store)
        #expect(coordinator.preferred && coordinator.menuChecked)
        #expect(coordinator.initialSource() == remapped)
        #expect(coordinator.isActive && store.mapping == [ours])
    }

    @Test func disabledPreferenceKeepsTheFnFlagSourceAndWritesNothing() {
        let store = FakeKeyStore()
        let (coordinator, _, _) = make(store, preferred: false)
        #expect(coordinator.initialSource() == .fnFlag)
        #expect(!coordinator.isActive && !coordinator.menuChecked)
        #expect(store.mapping == nil)
    }

    @Test func aFailedApplyFallsBackToTheFnFlag() {
        let store = FakeKeyStore()
        store.refuseWrites = true
        let (coordinator, _, preferences) = make(store)
        #expect(coordinator.initialSource() == .fnFlag)
        #expect(!coordinator.isActive && !coordinator.menuChecked)
        // The preference still says on, so the next launch tries again.
        #expect(FnRemapCoordinator.isPreferred(preferences))
    }

    @Test func turningItOffRestoresTheMappingAndSwitchesToTheFnFlag() {
        let store = FakeKeyStore()
        let (coordinator, _, preferences) = make(store)
        _ = coordinator.initialSource()
        #expect(coordinator.setEnabled(false) == .fnFlag)
        #expect(!coordinator.isActive && (store.mapping ?? []).isEmpty)
        #expect(!FnRemapCoordinator.isPreferred(preferences))
    }

    @Test func turningItBackOnReappliesLive() {
        let store = FakeKeyStore()
        let (coordinator, _, preferences) = make(store)
        _ = coordinator.initialSource()
        _ = coordinator.setEnabled(false)
        #expect(coordinator.setEnabled(true) == remapped)
        #expect(coordinator.isActive && store.mapping == [ours])
        #expect(FnRemapCoordinator.isPreferred(preferences))
    }

    @Test func aFailedTurnOnLeavesTheFnFlagAndThePreferenceOff() {
        let store = FakeKeyStore()
        let (coordinator, _, preferences) = make(store, preferred: false)
        _ = coordinator.initialSource()
        store.refuseWrites = true
        #expect(coordinator.setEnabled(true) == .fnFlag)
        #expect(!coordinator.isActive && !coordinator.menuChecked)
        #expect(!FnRemapCoordinator.isPreferred(preferences))
    }

    @Test func aFailedRestoreKeepsTheRemappedSourceBecauseFnStaysRemapped() {
        let store = FakeKeyStore()
        let (coordinator, _, _) = make(store)
        _ = coordinator.initialSource()
        store.refuseWrites = true
        #expect(coordinator.setEnabled(false) == remapped)
        #expect(coordinator.isActive && store.mapping == [ours])
    }

    @Test func theUsersOwnMappingSurvivesAToggleCycle() {
        let caps: FnRemapMapping.Entry = [FnRemapMapping.srcKey: 0x7_0000_0039, FnRemapMapping.dstKey: 0x7_0000_0029]
        let store = FakeKeyStore([caps])
        let (coordinator, _, _) = make(store)
        _ = coordinator.initialSource()
        #expect(store.mapping == [caps, ours])
        _ = coordinator.setEnabled(false)
        #expect(store.mapping == [caps])
        _ = coordinator.setEnabled(true)
        #expect(store.mapping == [caps, ours])
    }

    @Test func beforeInputStartsTheToggleOnlyRecordsThePreference() {
        let store = FakeKeyStore()
        let (coordinator, _, preferences) = make(store)
        #expect(coordinator.setEnabled(false) == .fnFlag)
        #expect(store.mapping == nil && !FnRemapCoordinator.isPreferred(preferences) && !coordinator.menuChecked)
    }

    @Test func deactivateRestoresForAStartThatFailed() {
        let store = FakeKeyStore()
        let (coordinator, _, _) = make(store)
        _ = coordinator.initialSource()
        #expect(coordinator.deactivate())
        #expect(!coordinator.isActive && (store.mapping ?? []).isEmpty)
    }
}
