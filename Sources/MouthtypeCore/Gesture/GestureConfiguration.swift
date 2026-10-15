import Foundation

/// How Mouthtype uses Hex's hotkey processor: Fn alone, 0.3 s minimum hold, double-tap lock on for hands-free.
public struct GestureConfiguration: Equatable, Sendable {
    public var hotkey: HotKey
    public var minimumKeyTime: TimeInterval
    public var doubleTapLockEnabled: Bool

    public init(
        hotkey: HotKey = HotKey(key: nil, modifiers: [.fn]),
        minimumKeyTime: TimeInterval = GestureConstants.modifierOnlyMinimumDuration,
        doubleTapLockEnabled: Bool = true
    ) {
        self.hotkey = hotkey
        self.minimumKeyTime = minimumKeyTime
        self.doubleTapLockEnabled = doubleTapLockEnabled
    }

    public static let `default` = GestureConfiguration()

    public func makeProcessor() -> HotKeyProcessor {
        HotKeyProcessor(
            hotkey: hotkey,
            doubleTapLockEnabled: doubleTapLockEnabled,
            minimumKeyTime: minimumKeyTime
        )
    }
}
