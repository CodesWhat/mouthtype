// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// When to re-enable a disabled event tap. Pure, so the schedule is tested.
///
/// The first disable is re-enabled at once. A re-enable that fails, or that
/// macOS undoes within `stableInterval`, counts as a failure, and the next
/// attempt waits 1 s, doubling to 30 s. A tap that stays enabled for
/// `stableInterval` starts over from an immediate re-enable.
struct TapRecovery {
    static let firstDelay: TimeInterval = 1
    static let maxDelay: TimeInterval = 30
    static let stableInterval: TimeInterval = 10

    /// Consecutive re-enables that did not stick.
    private(set) var failures = 0
    /// When the last re-enable took, if it has not been undone since.
    private var enabledAt: Date?

    /// Seconds to wait before the next attempt after `failures` failures.
    static func delay(afterFailures failures: Int) -> TimeInterval {
        guard failures > 0 else { return 0 }
        let exponent = Double(min(failures - 1, 16))
        return min(firstDelay * pow(2, exponent), maxDelay)
    }

    /// The tap was found disabled. Returns seconds to wait before re-enabling.
    mutating func disabled(at now: Date) -> TimeInterval {
        if let enabledAt, now.timeIntervalSince(enabledAt) < Self.stableInterval {
            failures += 1
        } else {
            failures = 0
        }
        enabledAt = nil
        return Self.delay(afterFailures: failures)
    }

    /// `tapEnable` did not take. Returns seconds to wait before the next try.
    mutating func enableFailed() -> TimeInterval {
        failures += 1
        enabledAt = nil
        return Self.delay(afterFailures: failures)
    }

    /// `tapEnable` took and `tapIsEnabled` confirmed it.
    mutating func enabled(at now: Date) {
        enabledAt = now
    }
}
