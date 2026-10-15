// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation
import IOKit.hid

/// What the system does when the Globe (Fn) key is pressed alone, read from `AppleFnUsageType`
/// in the `com.apple.HIToolbox` domain: 0 Do Nothing, 1 Change Input Source, 2 Show Emoji & Symbols,
/// 3 Start Dictation. A missing key means the OS default, which is Show Emoji & Symbols on current macOS.
public struct GlobeKeyCheck: Equatable, Sendable {
    public enum Action: Equatable, Sendable {
        case doNothing, changeInputSource, showEmoji, startDictation
    }

    public var action: Action
    /// A keyboard with an Fn/Globe key is likely attached.
    public var fnKeyPresent: Bool

    public var hasConflict: Bool { fnKeyPresent && action != .doNothing }

    public var menuText: String? {
        guard hasConflict else { return nil }
        switch action {
        case .doNothing: return nil
        case .changeInputSource: return "Globe key changes input source"
        case .showEmoji: return "Globe key opens Emoji & Symbols"
        case .startDictation: return "Globe key starts Dictation"
        }
    }

    public static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!

    /// `value` is `AppleFnUsageType`, nil when the key is absent.
    public static func action(forUsageType value: Int?) -> Action {
        switch value {
        case 0: .doNothing
        case 1: .changeInputSource
        case 3: .startDictation
        default: .showEmoji
        }
    }

    public static func current() -> GlobeKeyCheck {
        GlobeKeyCheck(action: action(forUsageType: readUsageType()), fnKeyPresent: fnKeyLikelyPresent())
    }

    static func readUsageType() -> Int? {
        guard let value = CFPreferencesCopyAppValue("AppleFnUsageType" as CFString, "com.apple.HIToolbox" as CFString) else { return nil }
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }

    /// There is no public API that says "this keyboard has an Fn key", and reading a keyboard's elements means
    /// opening it, which raises the Input Monitoring prompt. So this is a heuristic over device properties, which
    /// are readable without opening: a built-in keyboard (every Mac laptop's has Fn/Globe) or an Apple-branded
    /// external one counts. A desktop with only a third-party keyboard reads as absent.
    static func fnKeyLikelyPresent() -> Bool {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatching(manager, ["DeviceUsagePage": 1, "DeviceUsage": 6] as CFDictionary)
        guard let devices = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> else { return false }
        return devices.contains { device in
            if let builtIn = IOHIDDeviceGetProperty(device, "Built-In" as CFString) as? NSNumber, builtIn.boolValue { return true }
            let product = IOHIDDeviceGetProperty(device, "Product" as CFString) as? String ?? ""
            return product.contains("Apple") || product.contains("Magic Keyboard")
        }
    }
}
