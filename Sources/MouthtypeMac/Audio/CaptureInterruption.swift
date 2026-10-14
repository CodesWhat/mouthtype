import Foundation

enum CaptureInterruption {
    /// Wraps a main-actor handler for a Core Audio thread: the returned closure is formed here, outside any actor,
    /// and hops to the main actor itself. A closure formed inside a main-actor type and run off the main thread
    /// trips the runtime's isolation check, so callers hand the handler over instead of building the closure.
    static func hop(to handler: @escaping @MainActor () -> Void) -> @Sendable () -> Void {
        { Task { @MainActor in handler() } }
    }
}
