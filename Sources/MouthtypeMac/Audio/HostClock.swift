// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Darwin

/// Host time in nanoseconds: one unit above the audio render callback. `CGEvent.timestamp` is already
/// nanoseconds since boot (not `mach_absolute_time` ticks), so it compares directly with `now()`. Core Audio
/// stamps buffers in raw mach ticks (`mHostTime`); convert those with `nanoseconds(fromHostTime:)` as they enter.
enum HostClock {

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// Now, in host nanoseconds.
    static func now() -> UInt64 {
        nanoseconds(fromHostTime: mach_absolute_time())
    }

    /// A raw mach tick count (`AudioTimeStamp.mHostTime`, `AVAudioTime.hostTime`,
    /// `mach_absolute_time()`) in host nanoseconds. Never call this on a `CGEvent.timestamp`.
    static func nanoseconds(fromHostTime hostTime: UInt64) -> UInt64 {
        let info = timebase
        if info.numer == info.denom { return hostTime }
        return UInt64((Double(hostTime) * Double(info.numer) / Double(info.denom)).rounded())
    }

    /// Seconds from `start` to `end`, negative if `end` came first.
    static func seconds(from start: UInt64, to end: UInt64) -> Double {
        Double(Int64(bitPattern: end &- start)) / 1_000_000_000
    }
}
