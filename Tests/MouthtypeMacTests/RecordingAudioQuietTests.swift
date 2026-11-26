import Foundation
import Testing
@testable import MouthtypeMac

@MainActor private final class OutputObservation: QuietOutputObservation {
    var changed = false
    var cancelled = false
    func cancel() { cancelled = true }
}

private enum OutputFailure: Error { case unavailable }

@MainActor private final class QuietOutputFake: QuietOutputAccess {
    var current = QuietOutput(id: 1, uid: "speakers")
    var identity = QuietOutput(id: 1, uid: "speakers")
    var muted = false
    var unavailable = false
    var writeFails = false
    var observeFails = false
    var beforeRead: (() -> Void)?
    var writes: [(UInt32, Bool)] = []
    var observations: [OutputObservation] = []
    func currentOutput() throws -> QuietOutput {
        if unavailable { throw OutputFailure.unavailable }
        return current
    }
    func isMuted(_ output: QuietOutput) throws -> Bool {
        guard !unavailable, identity == output else { throw OutputFailure.unavailable }
        beforeRead?()
        return muted
    }
    func setMuted(_ muted: Bool, output: QuietOutput) throws {
        guard !writeFails, identity == output else { throw OutputFailure.unavailable }
        writes.append((output.id, muted))
        self.muted = muted
        observations.filter { !$0.cancelled }.forEach { $0.changed = true }
    }
    func observeChanges(_ output: QuietOutput) throws -> any QuietOutputObservation {
        if observeFails { throw OutputFailure.unavailable }
        let observation = OutputObservation()
        observations.append(observation)
        return observation
    }
    func userChanged(muted: Bool? = nil) {
        if let muted { self.muted = muted }
        observations.filter { !$0.cancelled }.forEach { $0.changed = true }
    }
}

@MainActor @Suite struct RecordingAudioQuietTests {
    @Test func offAndPreexistingMuteAreNeverChanged() {
        let output = QuietOutputFake()
        let off = RecordingAudioQuiet(output: output, enabled: { false })
        off.begin(); off.end()
        #expect(output.writes.isEmpty && output.observations.isEmpty)
        output.muted = true
        let on = RecordingAudioQuiet(output: output, enabled: { true })
        on.begin(); on.end()
        #expect(output.writes.isEmpty && output.observations.isEmpty)
    }

    @Test func restoresOnlyItsOwnMuteOnce() {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin(); quiet.begin()
        #expect(output.muted)
        #expect(output.writes.count == 1)
        #expect(output.observations.count == 1)
        quiet.end(); quiet.end()
        #expect(!output.muted)
        #expect(output.writes.map { $0.1 } == [true, false])
        #expect(output.observations.first?.cancelled == true)
    }

    @Test(arguments: [true, false]) func userChangesRelinquishRestoration(remute: Bool) {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin()
        if remute { output.userChanged(muted: false); output.userChanged(muted: true) } else { output.userChanged() }  // Volume change while still muted.
        quiet.end()
        #expect(output.writes.map { $0.1 } == [true])
        #expect(output.muted)
        #expect(output.observations.first?.cancelled == true)
    }

    @Test func userChangeDuringRestoreReadIsNotOverwritten() {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin()
        output.beforeRead = { output.userChanged() }
        quiet.end()
        #expect(output.writes.map { $0.1 } == [true])
        #expect(output.observations.first?.cancelled == true)
    }

    @Test func restoresOriginalDeviceInsteadOfNewDefault() {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin()
        output.current = QuietOutput(id: 2, uid: "headphones")
        quiet.end()
        #expect(output.writes.map { $0.0 } == [1, 1])
        #expect(!output.muted)
    }

    @Test func disconnectedOrReusedDeviceIsNotWritten() {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        quiet.begin()
        output.identity = QuietOutput(id: 1, uid: "different-device")
        quiet.end()
        #expect(output.writes.map { $0.1 } == [true])
        #expect(output.observations.first?.cancelled == true)
    }

    @Test func failuresDoNotOwnOrInventOutputChanges() {
        let output = QuietOutputFake()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true })
        output.unavailable = true
        quiet.begin(); quiet.end()
        #expect(output.writes.isEmpty)
        output.unavailable = false
        output.writeFails = true
        quiet.begin(); quiet.end()
        #expect(output.writes.isEmpty)
        output.writeFails = false
        output.observeFails = true
        quiet.begin(); quiet.end()
        #expect(output.writes.map { $0.1 } == [true, false])
        #expect(!output.muted)
    }

    @Test func preferenceIsOnByDefaultAndExplicitOffPersists() {
        let name = "QuietAudioTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(QuietAudioPreference.isEnabled(defaults))
        QuietAudioPreference.set(false, in: defaults)
        #expect(!QuietAudioPreference.isEnabled(defaults))
        QuietAudioPreference.set(true, in: defaults)
        #expect(QuietAudioPreference.isEnabled(defaults))
    }

    @Test func aCrashedMuteIsRestoredOnNextLaunch() {
        let output = QuietOutputFake()
        let marker = InMemoryQuietMuteMarker()
        let crashed = RecordingAudioQuiet(output: output, enabled: { true }, marker: marker)
        crashed.begin()  // Process dies here: end() never runs.
        #expect(output.muted && marker.markedUID == "speakers")
        let relaunched = RecordingAudioQuiet(output: output, enabled: { true }, marker: marker)
        #expect(relaunched.recoverFromCrash())
        #expect(!output.muted)
        #expect(marker.markedUID == nil)
    }

    @Test func aCleanEndLeavesNothingToRecover() {
        let output = QuietOutputFake()
        let marker = InMemoryQuietMuteMarker()
        let quiet = RecordingAudioQuiet(output: output, enabled: { true }, marker: marker)
        quiet.begin(); quiet.end()
        #expect(marker.markedUID == nil)
        output.muted = true  // The user's own mute later.
        #expect(!quiet.recoverFromCrash())
        #expect(output.muted)
    }

    @Test func aStaleMarkerNeverUnmutesAnotherDeviceOrAnAlreadyUnmutedOne() {
        let output = QuietOutputFake()
        let marker = InMemoryQuietMuteMarker()
        marker.markedUID = "headphones"
        output.muted = true
        let quiet = RecordingAudioQuiet(output: output, enabled: { true }, marker: marker)
        #expect(!quiet.recoverFromCrash())
        #expect(output.muted && output.writes.isEmpty && marker.markedUID == nil)
        marker.markedUID = "speakers"
        output.muted = false
        #expect(!quiet.recoverFromCrash())
        #expect(output.writes.isEmpty && marker.markedUID == nil)
    }

    @Test func aFailedMuteWriteLeavesNoMarker() {
        let output = QuietOutputFake()
        output.writeFails = true
        let marker = InMemoryQuietMuteMarker()
        RecordingAudioQuiet(output: output, enabled: { true }, marker: marker).begin()
        #expect(marker.markedUID == nil)
    }

    @Test func defaultsMarkerRoundTrips() throws {
        let defaults = try #require(UserDefaults(suiteName: "RecordingAudioQuietTests.\(UUID().uuidString)"))
        let marker = DefaultsQuietMuteMarker(defaults)
        #expect(marker.markedUID == nil)
        marker.markedUID = "speakers"
        #expect(DefaultsQuietMuteMarker(defaults).markedUID == "speakers")
        marker.markedUID = nil
        #expect(DefaultsQuietMuteMarker(defaults).markedUID == nil)
    }
}
