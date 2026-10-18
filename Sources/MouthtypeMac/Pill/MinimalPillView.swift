import AppKit

/// The Minimal pill: Matrix's silhouette, slots, controls and motion with ten plain 2 pt bars at 4 pt pitch and system
/// text. It follows the system appearance: a light body with ink #1D1D1F, or the Matrix dark body with ink #F4F3E8.
@MainActor
final class MinimalPillView: SquirclePillView {
    init(frame: NSRect, size: PillScale = .standard) {
        super.init(frame: frame, size: size, flavor: .minimal)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
