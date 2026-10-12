// Adapted from Hex (https://github.com/kitlangton/Hex, f58d52c), MIT License, Copyright (c) 2025 Kit Langton.

import Foundation

public struct Modifier: Hashable, Sendable {
    public enum Kind: String, CaseIterable, Sendable {
        case command, option, shift, control, fn
    }

    public enum Side: String, CaseIterable, Sendable {
        case either, left, right
    }

    public var kind: Kind
    public var side: Side

    public init(kind: Kind, side: Side = .either) {
        self.kind = kind
        self.side = side
    }

    public static let command = Modifier(kind: .command)
    public static let option = Modifier(kind: .option)
    public static let shift = Modifier(kind: .shift)
    public static let control = Modifier(kind: .control)
    public static let fn = Modifier(kind: .fn)

    func matches(_ other: Modifier) -> Bool {
        guard kind == other.kind else { return false }
        if side == .either || other.side == .either { return true }
        return side == other.side
    }
}

public struct Modifiers: Equatable, ExpressibleByArrayLiteral, Sendable {
    var modifiers: Set<Modifier>

    public var isEmpty: Bool {
        modifiers.isEmpty
    }

    public init(modifiers: Set<Modifier>) {
        self.modifiers = modifiers
    }

    public init(arrayLiteral elements: Modifier...) {
        modifiers = Set(elements)
    }

    public func contains(_ modifier: Modifier) -> Bool {
        modifiers.contains(where: { $0.matches(modifier) })
    }

    public func contains(kind: Modifier.Kind) -> Bool {
        modifiers.contains(where: { $0.kind == kind })
    }

    public func isSubset(of other: Modifiers) -> Bool {
        modifiers.allSatisfy { element in
            other.contains(element)
        }
    }

    public func matchesExactly(_ expected: Modifiers) -> Bool {
        guard expected.modifiers.allSatisfy({ requirement in self.contains(requirement) }) else {
            return false
        }

        let allowedKinds = Set(expected.modifiers.map { $0.kind })

        return modifiers.allSatisfy { candidate in
            guard allowedKinds.contains(candidate.kind) else { return false }
            guard let requirement = expected.modifiers.first(where: { $0.kind == candidate.kind }) else {
                return false
            }
            return candidate.matches(requirement)
        }
    }
}

public struct HotKey: Equatable, Sendable {
    public var key: Key?
    public var modifiers: Modifiers

    public init(key: Key?, modifiers: Modifiers) {
        self.key = key
        self.modifiers = modifiers
    }
}
