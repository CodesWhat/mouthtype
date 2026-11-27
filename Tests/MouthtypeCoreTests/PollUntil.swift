import Testing

/// Polls `condition` until it holds or `deadline` passes, so a test waits for the
/// observable result instead of a fixed sleep that flakes when the machine is loaded.
func pollUntil(
    deadline: Duration = .seconds(30),
    sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @Sendable () -> Bool
) async {
    let clock = ContinuousClock()
    let end = clock.now + deadline
    while !condition(), clock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    if !condition() { Issue.record("pollUntil: condition never held within \(deadline)", sourceLocation: sourceLocation) }
}
