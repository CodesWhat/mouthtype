import Foundation

public enum RecordingMode: String, CaseIterable, Sendable {
    case hold, toggle
}

/// How Mouthtype uses Hex's hotkey processor: Fn alone, 0.3 s minimum hold, double-tap lock on for hands-free.
public struct GestureConfiguration: Equatable, Sendable {
    public var hotkey: HotKey
    public var minimumKeyTime: TimeInterval
    public var doubleTapLockEnabled: Bool
    public var recordingMode: RecordingMode

    public init(
        hotkey: HotKey = HotKey(key: nil, modifiers: [.fn]),
        minimumKeyTime: TimeInterval = GestureConstants.modifierOnlyMinimumDuration,
        doubleTapLockEnabled: Bool = true,
        recordingMode: RecordingMode = .hold
    ) {
        self.hotkey = hotkey
        self.minimumKeyTime = minimumKeyTime
        self.doubleTapLockEnabled = doubleTapLockEnabled
        self.recordingMode = recordingMode
    }

    public static let `default` = GestureConfiguration()

    public func makeProcessor() -> HotKeyProcessor {
        HotKeyProcessor(
            hotkey: hotkey,
            doubleTapLockEnabled: doubleTapLockEnabled,
            minimumKeyTime: minimumKeyTime,
            recordingMode: recordingMode
        )
    }
}
