import Foundation
import FnRemapKit
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

    @Test func verifyRepairsALostMappingAndStaysRemapped() {
        let store = FakeKeyStore()
        let (coordinator, _, _) = make(store)
        _ = coordinator.initialSource()
        store.mapping = []
        #expect(coordinator.verify())
        #expect(coordinator.isActive && coordinator.source == remapped)
        #expect(store.mapping == [ours])
    }

    @Test func verifyFallsBackToTheFnFlagWhenRepairFails() {
        let store = FakeKeyStore()
        let (coordinator, marker, _) = make(store)
        _ = coordinator.initialSource()
        store.mapping = []
        store.refuseWrites = true
        #expect(!coordinator.verify())
        #expect(!coordinator.isActive && coordinator.source == .fnFlag)
        _ = marker
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

@MainActor
private final class FakeGuardian: FnGuarding {
    private(set) var starts = 0
    private(set) var stops = 0
    private(set) var restorings: [FnRemapMapping.Entry?] = []
    func start(restoring: FnRemapMapping.Entry?) { starts += 1; restorings.append(restoring) }
    func stop() { stops += 1 }
}

@MainActor
@Suite(.serialized) struct FnRemapGuardianTests {
    private func make(_ store: FakeKeyStore, guardian: FakeGuardian) -> FnRemapCoordinator {
        let marker = UserDefaults(suiteName: "remap-guardian-marker-\(UUID().uuidString)")!
        let preferences = UserDefaults(suiteName: "remap-guardian-prefs-\(UUID().uuidString)")!
        return FnRemapCoordinator(remap: FnRemap(store: store, defaults: marker), preferences: preferences, guardian: guardian)
    }

    @Test func guardStartsWithTheRemapAndStopsWhenItIsTurnedOff() {
        let guardian = FakeGuardian()
        let coordinator = make(FakeKeyStore(), guardian: guardian)
        _ = coordinator.initialSource()
        #expect(guardian.starts == 1 && guardian.stops == 0)
        _ = coordinator.setEnabled(false)
        #expect(guardian.stops == 1)
        _ = coordinator.setEnabled(true)
        #expect(guardian.starts == 2)
    }

    @Test func guardIsToldWhichUserMappingTheRemapDisplaced() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0029]
        let guardian = FakeGuardian()
        let coordinator = make(FakeKeyStore([theirFn]), guardian: guardian)
        _ = coordinator.initialSource()
        #expect(guardian.restorings == [theirFn])
    }

    @Test func guardGetsNothingToRestoreWhenFnWasUnmapped() {
        let guardian = FakeGuardian()
        let coordinator = make(FakeKeyStore(), guardian: guardian)
        _ = coordinator.initialSource()
        #expect(guardian.restorings == [nil])
    }

    @Test func guardRestartsWithTheNewDisplacedMappingAfterARepair() {
        let theirFn: FnRemapMapping.Entry = [FnRemapMapping.srcKey: FnRemapMapping.fnSource, FnRemapMapping.dstKey: 0x7_0000_0029]
        let store = FakeKeyStore()
        let guardian = FakeGuardian()
        let coordinator = make(store, guardian: guardian)
        _ = coordinator.initialSource()
        store.mapping = [theirFn]
        #expect(coordinator.verify())
        #expect(guardian.stops == 1 && guardian.restorings == [nil, theirFn])
    }

    @Test func noGuardWhenTheRemapIsRefused() {
        let store = FakeKeyStore()
        store.refuseWrites = true
        let guardian = FakeGuardian()
        let coordinator = make(store, guardian: guardian)
        _ = coordinator.initialSource()
        #expect(guardian.starts == 0)
    }

    @Test func guardKeepsWatchingWhenTheRestoreFails() {
        let store = FakeKeyStore()
        let guardian = FakeGuardian()
        let coordinator = make(store, guardian: guardian)
        _ = coordinator.initialSource()
        store.refuseWrites = true
        #expect(!coordinator.deactivate())
        #expect(guardian.stops == 0)
    }
}

@MainActor
@Suite(.serialized) struct FnGuardLauncherTests {
    private func script(_ body: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("fn-guard-launcher-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("fake-guard")
        try "#!/bin/sh\n\(body)\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    @Test func aMissingBinaryIsSurvived() {
        let launcher = FnGuardLauncher(executable: URL(fileURLWithPath: "/nonexistent/mouthtype-fn-guard"))
        launcher.start(restoring: nil)
        launcher.start(restoring: nil)
        #expect(launcher.pid == nil && !launcher.isRunning)
        launcher.stop()
    }

    @Test func startIsIdempotentAndStopEndsTheProcessInItsOwnSession() throws {
        let url = try script("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let launcher = FnGuardLauncher(executable: url)
        launcher.start(restoring: nil)
        let first = try #require(launcher.pid)
        launcher.start(restoring: nil)
        #expect(launcher.pid == first && launcher.isRunning)
        #expect(getsid(first) == first, "not a session leader")
        #expect(getsid(first) != getsid(getpid()))
        launcher.stop()
        #expect(launcher.pid == nil)
        launcher.start(restoring: nil)
        #expect(launcher.pid != nil && launcher.pid != first)
        launcher.stop()
    }

    @Test func stopEndsAGuardEvenWhenTheAppIgnoresSIGTERM() throws {
        let url = try script("exec /bin/sleep 30")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let previous = signal(SIGTERM, SIG_IGN)
        defer { signal(SIGTERM, previous) }
        let launcher = FnGuardLauncher(executable: url)
        launcher.start(restoring: nil)
        let pid = try #require(launcher.pid)
        launcher.stop()
        var gone = false
        for _ in 0..<200 where !gone {
            usleep(10_000)
            gone = kill(pid, 0) != 0 && errno == ESRCH
        }
        #expect(gone, "the guard survived SIGTERM")
    }

    @Test func aGuardThatExitedIsReplaced() throws {
        let url = try script("exit 0")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let launcher = FnGuardLauncher(executable: url)
        launcher.start(restoring: nil)
        let first = try #require(launcher.pid)
        while launcher.isRunning { usleep(10_000) }
        launcher.start(restoring: nil)
        #expect(launcher.pid != nil && launcher.pid != first)
        while launcher.isRunning { usleep(10_000) }
    }
}
