import Foundation

@MainActor
protocol RecordingAudioQuieting: AnyObject {
    func begin()
    func end()
}

struct QuietOutput: Equatable, Sendable {
    var id: UInt32
    var uid: String
}

@MainActor
protocol QuietOutputObservation: AnyObject {
    var changed: Bool { get }
    func cancel()
}

@MainActor
protocol QuietOutputAccess: AnyObject {
    func currentOutput() throws -> QuietOutput
    func isMuted(_ output: QuietOutput) throws -> Bool
    func setMuted(_ muted: Bool, output: QuietOutput) throws
    func observeChanges(_ output: QuietOutput) throws -> any QuietOutputObservation
}

/// Remembers the device we muted until we restore it, so a crash that skips `end()` can be repaired on next launch.
@MainActor
protocol QuietMuteMarkerStore: AnyObject {
    var markedUID: String? { get set }
}

@MainActor
final class InMemoryQuietMuteMarker: QuietMuteMarkerStore {
    var markedUID: String?
}

@MainActor
final class DefaultsQuietMuteMarker: QuietMuteMarkerStore {
    static let key = "quietOtherAudioMutedUID"
    private let defaults: UserDefaults
    init(_ defaults: UserDefaults = .standard) { self.defaults = defaults }
    var markedUID: String? {
        get { defaults.string(forKey: Self.key) }
        set { newValue == nil ? defaults.removeObject(forKey: Self.key) : defaults.set(newValue, forKey: Self.key) }
    }
}

@MainActor
final class RecordingAudioQuiet: RecordingAudioQuieting {
    private let output: any QuietOutputAccess
    private let enabled: @MainActor () -> Bool
    private let marker: any QuietMuteMarkerStore
    private var owned: (device: QuietOutput, observation: any QuietOutputObservation)?

    init(
        output: any QuietOutputAccess, enabled: @escaping @MainActor () -> Bool,
        marker: any QuietMuteMarkerStore = InMemoryQuietMuteMarker()
    ) {
        self.output = output
        self.enabled = enabled
        self.marker = marker
    }

    /// Call once at launch. If a previous run muted the output and never restored it (a crash or force-quit),
    /// unmute that output now. Returns true when it restored one. Only the current default output can be
    /// reached, so a marker for any other device is dropped without touching anything.
    @discardableResult
    func recoverFromCrash() -> Bool {
        guard owned == nil, let uid = marker.markedUID else { return false }
        marker.markedUID = nil
        guard let device = try? output.currentOutput(), device.uid == uid,
            (try? output.isMuted(device)) == true
        else {
            Log.app.notice("Stale quiet-audio marker cleared; the output was not left muted")
            return false
        }
        do {
            try output.setMuted(false, output: device)
            Log.app.notice("Restored output muted by a previous run that did not exit cleanly")
            return true
        } catch {
            Log.app.error("Could not restore output muted by a previous run")
            return false
        }
    }

    func begin() {
        guard owned == nil, enabled() else { return }
        do {
            let device = try output.currentOutput()
            guard try !output.isMuted(device) else { return }
            marker.markedUID = device.uid
            do { try output.setMuted(true, output: device) } catch {
                marker.markedUID = nil
                throw error
            }
            do {
                // The output adapter also filters delayed notifications from our mute write.
                let observation = try output.observeChanges(device)
                owned = (device, observation)
            } catch {
                if (try? output.isMuted(device)) == true { try? output.setMuted(false, output: device) }
                marker.markedUID = nil
            }
        } catch {
            // Quieting an unsupported or missing output never prevents a dictation.
        }
    }

    func end() {
        guard let ownership = owned else { return }
        owned = nil
        defer {
            marker.markedUID = nil
            ownership.observation.cancel()
        }
        guard (try? output.isMuted(ownership.device)) == true, !ownership.observation.changed else { return }
        try? output.setMuted(false, output: ownership.device)
    }
}

enum QuietAudioPreference {
    static let key = "quietOtherAudio"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.object(forKey: key) as? Bool ?? true }
    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}
