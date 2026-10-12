// Adapted from Hex (https://github.com/kitlangton/Hex, f58d52c), MIT License, Copyright (c) 2025 Kit Langton.

import Foundation

public struct KeyEvent: Equatable, Sendable {
    public let key: Key?
    public let modifiers: Modifiers

    public init(key: Key?, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
