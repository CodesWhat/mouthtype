import Foundation

/// Re-applies the audio retention policy on a timer. A tick that lands while the app is busy is retried after a short
/// delay instead of waiting out another full interval.
public enum AudioPurgeLoop {
    public static let interval: Duration = .seconds(6 * 60 * 60)
    public static let busyRetry: Duration = .seconds(5 * 60)

    /// Runs until the surrounding task is cancelled or `shouldStop` returns true.
    public static func run(
        interval: Duration = AudioPurgeLoop.interval,
        busyRetry: Duration = AudioPurgeLoop.busyRetry,
        sleep: @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
        shouldStop: @Sendable () async -> Bool,
        isIdle: @Sendable () async -> Bool,
        purge: @Sendable () async -> Void
    ) async {
        var wait = interval
        while !Task.isCancelled {
            await sleep(wait)
            if Task.isCancelled { return }
            if await shouldStop() { return }
            if await isIdle() {
                await purge()
                wait = interval
            } else {
                wait = busyRetry
            }
        }
    }
}
