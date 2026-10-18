import CoreGraphics

enum PillPlacement {
    struct Screen: Equatable {
        var frame: CGRect
        var visibleFrame: CGRect
    }

    /// Distance from the bottom of the visible frame (above the Dock) to the bottom of the pill.
    static let bottomInset: CGFloat = 12

    /// The screen containing `pointer`, else the first. Nil when there are no screens.
    static func screen(pointer: CGPoint, screens: [Screen]) -> Screen? {
        screens.first(where: { $0.frame.contains(pointer) }) ?? screens.first
    }

    /// Origin for a panel of `panelSize` whose pill sits `pillPadding` above the panel's bottom edge: bottom centre of
    /// the screen containing `pointer`, else the first screen. Nil when there are no screens.
    static func origin(pointer: CGPoint, screens: [Screen], panelSize: CGSize, pillPadding: CGFloat) -> CGPoint? {
        guard let screen = screen(pointer: pointer, screens: screens) else { return nil }
        let visible = screen.visibleFrame
        return CGPoint(
            x: visible.midX - panelSize.width / 2,
            y: visible.minY + bottomInset - pillPadding
        )
    }
}
