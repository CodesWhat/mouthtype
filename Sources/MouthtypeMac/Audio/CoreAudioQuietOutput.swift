import CoreAudio
import Foundation

@MainActor
final class CoreAudioQuietOutput: QuietOutputAccess {
    private enum Failure: Error { case unavailable, unsupported, status(OSStatus) }

    func currentOutput() throws -> QuietOutput {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        try check(AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id))
        guard id != kAudioObjectUnknown, let uid = InputDevice.uid(of: id) else { throw Failure.unavailable }
        return QuietOutput(id: id, uid: uid)
    }

    func isMuted(_ output: QuietOutput) throws -> Bool {
        try validate(output)
        var address = muteAddress
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        try check(AudioObjectGetPropertyData(output.id, &address, 0, nil, &size, &value))
        return value != 0
    }

    func setMuted(_ muted: Bool, output: QuietOutput) throws {
        try validate(output)
        var address = muteAddress
        var settable: DarwinBoolean = false
        try check(AudioObjectIsPropertySettable(output.id, &address, &settable))
        guard settable.boolValue else { throw Failure.unsupported }
        var value: UInt32 = muted ? 1 : 0
        try check(AudioObjectSetPropertyData(output.id, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value))
    }

    func observeChanges(_ output: QuietOutput) throws -> any QuietOutputObservation {
        try validate(output)
        return try CoreAudioQuietObservation(device: output.id)
    }

    private var muteAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
            mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
    }

    private func validate(_ output: QuietOutput) throws {
        guard InputDevice.uid(of: output.id) == output.uid else { throw Failure.unavailable }
    }

    private func check(_ status: OSStatus) throws {
        guard status == noErr else { throw Failure.status(status) }
    }
}

private final class QuietOutputChange: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var changed: Bool { lock.withLock { value } }
    func markChanged() { lock.withLock { value = true } }
}

@MainActor
private final class CoreAudioQuietObservation: QuietOutputObservation {
    private let change = QuietOutputChange()
    private var registration: QuietOutputListener?
    var changed: Bool { change.changed }

    init(device: AudioDeviceID) throws {
        registration = try QuietOutputListener(device: device, change: change)
    }

    func cancel() { registration = nil }
}

private final class QuietOutputListener {
    private let device: AudioDeviceID
    private var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertySelectorWildcard,
        mScope: kAudioDevicePropertyScopeOutput, mElement: kAudioObjectPropertyElementWildcard)
    private let block: AudioObjectPropertyListenerBlock

    init(device: AudioDeviceID, change: QuietOutputChange) throws {
        self.device = device
        block = { count, addresses in
            for address in UnsafeBufferPointer(start: addresses, count: Int(count)) {
                switch address.mSelector {
                case kAudioDevicePropertyMute:
                    var property = address
                    var muted: UInt32 = 0
                    var size = UInt32(MemoryLayout<UInt32>.size)
                    let read = AudioObjectGetPropertyData(device, &property, 0, nil, &size, &muted)
                    // Our mute can notify after registration. A matching value is still ours.
                    if read != noErr || muted == 0 { change.markChanged() }
                case kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyVolumeDecibels:
                    change.markChanged()
                default: break
                }
            }
        }
        // A nil queue marks ownership loss at the callback, before any MainActor hop.
        let status = AudioObjectAddPropertyListenerBlock(device, &address, nil, block)
        guard status == noErr else { throw NSError(domain: NSOSStatusErrorDomain, code: Int(status)) }
    }

    deinit { _ = AudioObjectRemovePropertyListenerBlock(device, &address, nil, block) }
}
