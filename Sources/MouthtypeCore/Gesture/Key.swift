import Foundation

/// A virtual key code. Replaces Hex's Sauce.Key so Core has no keyboard-layout dependency.
public struct Key: Hashable, Sendable {
    public var code: UInt16

    public init(code: UInt16) {
        self.code = code
    }

    public static let a = Key(code: 0)
    public static let c = Key(code: 8)
    public static let b = Key(code: 11)
    public static let g = Key(code: 5)
    public static let t = Key(code: 17)
    public static let u = Key(code: 32)
    public static let quote = Key(code: 39)
    public static let escape = Key(code: 53)
}
