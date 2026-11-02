import Foundation

/// Polls on the main actor until `condition` holds or the deadline passes, so a render test waits for the state it needs
/// instead of a fixed settle. Returns whether the condition held; the caller asserts on the real state afterward.
@MainActor
@discardableResult
func awaitCondition(timeout: Duration = .seconds(10), _ condition: @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return true
}
