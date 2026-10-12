import Foundation
import IOKit.hid

/// Reads and writes the HID system's key mapping.
public protocol KeyMappingStore {
    /// nil when the property is unset. Throws when it holds something this code doesn't understand.
    func read() throws -> [FnRemapMapping.Entry]?
    func write(_ mapping: [FnRemapMapping.Entry]) -> Bool
}

public enum KeyMappingError: Error, Equatable {
    case unsupportedShape
}

/// `IOHIDEventSystemClient` property access, the public API TN2450 points at.
public struct HIDKeyMappingStore: KeyMappingStore {
    static var propertyKey: CFString { "UserKeyMapping" as CFString }

    public init() {}

    public func read() throws -> [FnRemapMapping.Entry]? {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        guard let value = IOHIDEventSystemClientCopyProperty(client, Self.propertyKey) else { return nil }
        guard let array = value as? [[String: Any]] else { throw KeyMappingError.unsupportedShape }
        return try array.map { dictionary in
            var entry: FnRemapMapping.Entry = [:]
            for (key, raw) in dictionary {
                guard let number = raw as? NSNumber else { throw KeyMappingError.unsupportedShape }
                entry[key] = number.int64Value
            }
            return entry
        }
    }

    public func write(_ mapping: [FnRemapMapping.Entry]) -> Bool {
        let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
        let array = mapping.map { entry in entry.mapValues { NSNumber(value: $0) } } as NSArray
        return IOHIDEventSystemClientSetProperty(client, Self.propertyKey, array)
    }
}
