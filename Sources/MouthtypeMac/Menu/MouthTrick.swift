import Foundation

/// A short sequence the menu bar mouth plays when the menu is opened with Option held. Every frame is a template glyph, so the
/// trick follows the light and dark menu bar like the rest.
enum MouthTrick: CaseIterable, Equatable {
    case tongue, whistle

    struct Step: Equatable {
        let file: String
        let seconds: TimeInterval
    }

    /// Every file a trick can show, so the menu bar controller loads them once.
    static var glyphFiles: [String] {
        Array(Set(allCases.flatMap { ($0.steps + [$0.staticFrame]).map(\.file) })).sorted()
    }

    /// The sequence, 1.2 to 1.5 seconds in all. The last step hands back to the true glyph.
    var steps: [Step] {
        switch self {
        case .tongue:
            [
                Step(file: "recording0", seconds: 0.25), Step(file: "trick-tongue0", seconds: 0.2),
                Step(file: "trick-tongue1", seconds: 0.2), Step(file: "trick-tongue0", seconds: 0.2),
                Step(file: "trick-tongue1", seconds: 0.2), Step(file: "recording0", seconds: 0.2),
            ]
        case .whistle:
            [
                Step(file: "recording0", seconds: 0.2), Step(file: "trick-whistle0", seconds: 0.3),
                Step(file: "trick-whistle1", seconds: 0.25), Step(file: "trick-whistle0", seconds: 0.25),
                Step(file: "trick-whistle1", seconds: 0.25), Step(file: "trick-whistle0", seconds: 0.2),
            ]
        }
    }

    /// Reduce Motion: one still frame, held for a moment.
    var staticFrame: Step {
        switch self {
        case .tongue: Step(file: "trick-tongue0", seconds: 1.5)
        case .whistle: Step(file: "trick-whistle1", seconds: 1.5)
        }
    }
}

/// Plays a `MouthTrick` on the status item, and only while the icon is idle. The owner calls `cancel()` on every real state
/// change, which restores the true glyph at once. Nothing is persisted.
@MainActor final class MouthTrickPlayer {
    private(set) var isPlaying = false
    private(set) var current: MouthTrick?

    private let pick: () -> MouthTrick
    private let schedule: (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void
    private let show: (String) -> Void
    private let restore: () -> Void
    private let reduceMotion: () -> Bool
    private var cancelTimer: (() -> Void)?
    private var stepIndex = 0
    private var runID = 0

    /// `schedule` runs the closure after the delay and returns a function that cancels it.
    init(
        pick: @escaping () -> MouthTrick = { MouthTrick.allCases.randomElement() ?? .tongue },
        schedule: @escaping (TimeInterval, @escaping @MainActor () -> Void) -> () -> Void,
        show: @escaping (String) -> Void, restore: @escaping () -> Void, reduceMotion: @escaping () -> Bool
    ) {
        self.pick = pick
        self.schedule = schedule
        self.show = show
        self.restore = restore
        self.reduceMotion = reduceMotion
    }

    /// Starts a trick when the icon is idle and none is running. Returns whether one started.
    @discardableResult
    func start(icon: StatusIcon) -> Bool {
        guard icon == .idle, !isPlaying else { return false }
        let trick = pick()
        current = trick
        isPlaying = true
        runID += 1
        if reduceMotion() {
            let frame = trick.staticFrame
            show(frame.file)
            arm(after: frame.seconds, run: runID) { $0.finish() }
        } else {
            stepIndex = 0
            play(run: runID)
        }
        return true
    }

    /// Stops the trick, if one is running, and puts the true glyph back. Safe to call any time.
    func cancel() {
        guard isPlaying else { return }
        finish()
    }

    private func play(run: Int) {
        guard let trick = current, trick.steps.indices.contains(stepIndex) else { return finish() }
        let step = trick.steps[stepIndex]
        show(step.file)
        arm(after: step.seconds, run: run) { player in
            player.stepIndex += 1
            player.play(run: run)
        }
    }

    private func arm(after seconds: TimeInterval, run: Int, then next: @escaping @MainActor (MouthTrickPlayer) -> Void) {
        cancelTimer = schedule(seconds) { [weak self] in
            guard let self, self.isPlaying, self.runID == run else { return }
            next(self)
        }
    }

    private func finish() {
        cancelTimer?()
        cancelTimer = nil
        isPlaying = false
        current = nil
        stepIndex = 0
        runID += 1
        restore()
    }
}
