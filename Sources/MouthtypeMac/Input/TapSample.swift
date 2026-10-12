import CoreGraphics

/// The fields the tap callback copies out of an event. Everything downstream works on these.
public struct TapSample: Equatable, Sendable {
    public enum Kind: Equatable, Sendable {
        case flagsChanged, keyDown, keyUp

        init?(_ type: CGEventType) {
            switch type {
            case .flagsChanged: self = .flagsChanged
            case .keyDown: self = .keyDown
            case .keyUp: self = .keyUp
            default: return nil
            }
        }
    }

    public var kind: Kind
    public var keyCode: UInt16
    public var flags: UInt64
    /// Mach host time, the unit `CGEvent.timestamp` reports.
    public var timestamp: UInt64
    public var userData: Int64
    public var isAutorepeat: Bool

    public init(kind: Kind, keyCode: UInt16, flags: UInt64, timestamp: UInt64, userData: Int64 = 0, isAutorepeat: Bool = false) {
        self.kind = kind
        self.keyCode = keyCode
        self.flags = flags
        self.timestamp = timestamp
        self.userData = userData
        self.isAutorepeat = isAutorepeat
    }

    init?(type: CGEventType, event: CGEvent) {
        guard let kind = Kind(type) else { return nil }
        self.init(
            kind: kind,
            keyCode: UInt16(truncatingIfNeeded: event.getIntegerValueField(.keyboardEventKeycode)),
            flags: event.flags.rawValue,
            timestamp: event.timestamp,
            userData: event.getIntegerValueField(.eventSourceUserData),
            isAutorepeat: kind != .flagsChanged && event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        )
    }
}
