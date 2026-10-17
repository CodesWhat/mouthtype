// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import CoreAudio
import Foundation

/// The default input device as Core Audio reports it, read before any
/// capture path touches it. Checking here turns a missing device, or one that
/// reports 0 Hz or 0 channels, into a `CaptureError`.
struct InputDevice: Equatable, Sendable {
    var sampleRate: Double
    var channels: UInt32
    /// The Core Audio device, or `kAudioObjectUnknown` when not read from one.
    var id: AudioDeviceID = kAudioObjectUnknown

    /// The current default input. Throws `CaptureError.noInputDevice` if there
    /// is none, or `.invalidInputFormat` if it cannot be recorded.
    static func current() throws -> InputDevice {
        guard let id = defaultInputID() else { throw CaptureError.noInputDevice }
        let device = InputDevice(sampleRate: nominalSampleRate(id), channels: inputChannels(id), id: id)
        try validate(sampleRate: device.sampleRate, channels: device.channels)
        return device
    }

    static func availableMicrophones() throws -> [MicrophoneDevice] {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let status = AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size)
        guard status == noErr else { throw CaptureError.engineStartFailed(NSError(domain: NSOSStatusErrorDomain, code: Int(status))) }
        guard size > 0 else { return [] }
        let stride = MemoryLayout<AudioDeviceID>.stride
        guard Int(size) % stride == 0 else { throw CaptureError.noInputDevice }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / stride)
        let capacity = size
        let result = ids.withUnsafeMutableBytes { raw in
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, raw.baseAddress!)
        }
        guard result == noErr, size <= capacity, Int(size) % stride == 0 else {
            throw CaptureError.engineStartFailed(NSError(domain: NSOSStatusErrorDomain, code: Int(result)))
        }
        return ids.prefix(Int(size) / stride).compactMap { id in
            let input = InputDevice(sampleRate: nominalSampleRate(id), channels: inputChannels(id), id: id)
            guard isAlive(id), (try? validate(sampleRate: input.sampleRate, channels: input.channels)) != nil,
                  let uid = uid(of: id), !uid.isEmpty else { return nil }
            return MicrophoneDevice(uid: uid, name: name(of: id) ?? "Microphone", input: input)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    static func isAlive(_ id: AudioDeviceID) -> Bool {
        var alive: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsAlive,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &alive) == noErr && alive != 0
    }

    /// The device's name as the Sound settings show it, or nil.
    static func name(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioObjectPropertyName)
    }

    /// The device's persistent unique ID (stable across reboots), or nil.
    static func uid(of id: AudioDeviceID) -> String? {
        stringProperty(id, kAudioDevicePropertyDeviceUID)
    }

    /// How the device is attached: built-in, usb, bluetooth, virtual, aggregate, or other.
    static func transport(of id: AudioDeviceID) -> String {
        var type: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &type) == noErr else { return "other" }
        return transportName(type)
    }

    static func transportName(_ type: UInt32) -> String {
        switch type {
        case kAudioDeviceTransportTypeBuiltIn: return "built-in"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        default: return "other"
        }
    }

    private static func stringProperty(_ id: AudioDeviceID, _ selector: AudioObjectPropertySelector) -> String? {
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &value) == noErr,
              let string = value?.takeRetainedValue()
        else { return nil }
        return string as String
    }

    /// Throws `CaptureError.invalidInputFormat` unless both are positive.
    static func validate(sampleRate: Double, channels: UInt32) throws {
        guard sampleRate > 0, sampleRate.isFinite, channels > 0 else {
            throw CaptureError.invalidInputFormat(sampleRate: sampleRate, channels: channels)
        }
    }

    static func defaultInputID() -> AudioDeviceID? {
        var id = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id
        )
        guard status == noErr, id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func nominalSampleRate(_ id: AudioDeviceID) -> Double {
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyNominalSampleRate,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &rate) == noErr else { return 0 }
        return rate
    }

    static func inputChannels(_ id: AudioDeviceID) -> UInt32 {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { raw.deallocate() }
        let list = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + $1.mNumberChannels }
    }
}
