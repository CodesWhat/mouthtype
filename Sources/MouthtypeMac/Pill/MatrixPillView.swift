import AppKit

/// The Matrix pill: a 30 pt squircle with a 13 x 7 amber dot matrix, a breathing REC lamp and a JetBrains Mono clock
/// once locked. On a light desktop the readout sits in a pager LCD window.
@MainActor
final class MatrixPillView: SquirclePillView {
    init(frame: NSRect, size: PillScale = .standard) {
        super.init(frame: frame, size: size, flavor: .matrix)
    }

    required init?(coder: NSCoder) { fatalError("not used") }
}
