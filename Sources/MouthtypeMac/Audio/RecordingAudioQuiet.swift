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

@MainActor
final class RecordingAudioQuiet: RecordingAudioQuieting {
    private let output: any QuietOutputAccess
    private let enabled: @MainActor () -> Bool
    private var owned: (device: QuietOutput, observation: any QuietOutputObservation)?

    init(output: any QuietOutputAccess, enabled: @escaping @MainActor () -> Bool) {
        self.output = output
        self.enabled = enabled
    }

    func begin() {
        guard owned == nil, enabled() else { return }
        do {
            let device = try output.currentOutput()
            guard try !output.isMuted(device) else { return }
            try output.setMuted(true, output: device)
            do {
                // Subscribe after our write rather than registering during the mutation.
                let observation = try output.observeChanges(device)
                owned = (device, observation)
            } catch {
                if (try? output.isMuted(device)) == true { try? output.setMuted(false, output: device) }
            }
        } catch {
            // Quieting an unsupported or missing output never prevents a dictation.
        }
    }

    func end() {
        guard let ownership = owned else { return }
        owned = nil
        defer { ownership.observation.cancel() }
        guard (try? output.isMuted(ownership.device)) == true, !ownership.observation.changed else { return }
        try? output.setMuted(false, output: ownership.device)
    }
}

enum QuietAudioPreference {
    static let key = "quietOtherAudio"
    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool { defaults.bool(forKey: key) }
    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) { defaults.set(enabled, forKey: key) }
}
