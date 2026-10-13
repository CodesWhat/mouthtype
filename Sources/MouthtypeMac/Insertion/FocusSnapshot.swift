// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MouthtypeCore

/// What had keyboard focus at one moment: the frontmost app, its focused element, and whether that element is a
/// secure (password) field. Taken at dictation start and again right before delivery, over Accessibility.
public struct FocusSnapshot: Sendable {
    public var pid: pid_t?
    public var bundleID: String?
    public var appName: String?
    public var windowTitle: String?
    public var role: String?
    public var subrole: String?
    public var isSecure: Bool
    /// The focused element, if the app exposes one over Accessibility.
    var element: FocusedElement?

    init(
        pid: pid_t? = nil, bundleID: String? = nil, appName: String? = nil, windowTitle: String? = nil,
        role: String? = nil, subrole: String? = nil, isSecure: Bool = false, element: FocusedElement? = nil
    ) {
        self.pid = pid
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.role = role
        self.subrole = subrole
        self.isSecure = isSecure
        self.element = element
    }

    public var target: DictationTarget {
        DictationTarget(bundleID: bundleID, appName: appName, windowTitle: windowTitle, fieldRole: role, isSecure: isSecure)
    }

    /// Whether focus moved from `self` to `now`. The app must match. The element must match when both snapshots saw
    /// one; an element seen only once is not a change, because Chromium and Electron apps build their Accessibility
    /// tree lazily and may expose nothing at dictation start.
    func hasChanged(to now: FocusSnapshot) -> Bool {
        if pid != now.pid { return true }
        if let element, let other = now.element, element != other { return true }
        return false
    }
}

/// An Accessibility element compared by identity (`CFEqual`).
struct FocusedElement: Equatable, @unchecked Sendable {
    let ref: AXUIElement

    init(_ ref: AXUIElement) {
        self.ref = ref
    }

    static func == (lhs: FocusedElement, rhs: FocusedElement) -> Bool {
        CFEqual(lhs.ref, rhs.ref)
    }
}

/// What a correction watch checks on each poll.
struct FocusProbe: Sendable {
    var pid: pid_t?
    var element: FocusedElement?
    var isSecure: Bool
}

/// The Accessibility and secure-input reads delivery needs. The system in the app, a fake in tests.
@MainActor
protocol FocusReading: AnyObject {
    func snapshot() -> FocusSnapshot
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor
    /// A bounded window of text around the cursor, for the cleanup pass. Nil when the app doesn't say.
    func insertionContext(of element: FocusedElement) -> InsertionContext?
    var isSecureInputEnabled: Bool { get }
}

extension FocusReading {
    func insertionContext(of element: FocusedElement) -> InsertionContext? { nil }
}

@MainActor
final class AccessibilityFocusReader: FocusReading {
    /// Upper bound on each Accessibility call, so a hung app cannot stall the main thread (and with it the hotkey tap).
    static let messagingTimeout: Float = 0.25

    var isSecureInputEnabled: Bool { IsSecureEventInputEnabled() }

    func snapshot() -> FocusSnapshot {
        let app = NSWorkspace.shared.frontmostApplication
        var snapshot = FocusSnapshot(pid: app?.processIdentifier, bundleID: app?.bundleIdentifier, appName: app?.localizedName)

        let systemWide = bounded(AXUIElementCreateSystemWide())
        guard let element = elementValue(systemWide, kAXFocusedUIElementAttribute) else {
            if let pid = snapshot.pid {
                let appElement = bounded(AXUIElementCreateApplication(pid))
                snapshot.windowTitle = elementValue(appElement, kAXFocusedWindowAttribute).flatMap(title(of:))
            }
            return snapshot
        }
        bounded(element)
        snapshot.element = FocusedElement(element)
        snapshot.role = stringValue(element, kAXRoleAttribute)
        snapshot.subrole = stringValue(element, kAXSubroleAttribute)
        snapshot.isSecure = isSecure(element, subrole: snapshot.subrole)
        snapshot.windowTitle = elementValue(element, kAXWindowAttribute).flatMap(title(of:))
        return snapshot
    }

    /// The character before the insertion point, for `Spacing`. Reads the selected range, then the text just before
    /// it. Ranges count UTF-16 units, so two are read and the last character kept: one alone could be half an emoji.
    /// Falls back to the whole value for apps without `AXStringForRange`. Never call on a secure field.
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor {
        let ref = bounded(element.ref)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return .unknown }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0 else { return .unknown }
        // Terminals such as Ghostty report position 0 wherever the cursor is, so 0 is the start only in an empty field.
        if range.location == 0 { return characterCount(ref) == 0 ? .start : .unknown }

        let length = min(range.location, 2)
        var before = CFRange(location: range.location - length, length: length)
        var text: CFTypeRef?
        if let query = AXValueCreate(.cfRange, &before),
           AXUIElementCopyParameterizedAttributeValue(ref, kAXStringForRangeParameterizedAttribute as CFString, query, &text) == .success,
           let character = (text as? String)?.last {
            return .character(character)
        }

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXValueAttribute as CFString, &value) == .success,
              let value = value as? String else { return .unknown }
        let units = value.utf16
        guard range.location <= units.count else { return .unknown }
        let end = units.index(units.startIndex, offsetBy: range.location)
        let start = units.index(end, offsetBy: -length)
        return String(units[start..<end]).flatMap { $0.last }.map(TextBeforeCursor.character) ?? .unknown
    }

    /// Characters read before and after the cursor. Held only for the one cleanup run; never stored or logged.
    static let contextBefore = 300
    static let contextAfter = 40

    /// Never call on a secure field. A terminal that reports position 0 wherever the cursor is gives nil.
    func insertionContext(of element: FocusedElement) -> InsertionContext? {
        let ref = bounded(element.ref)
        var rangeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(ref, kAXSelectedTextRangeAttribute as CFString, &rangeValue) == .success,
              let rangeValue, CFGetTypeID(rangeValue) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeValue as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        let count = characterCount(ref)
        if range.location == 0 {
            return count == 0 ? InsertionContext(before: "", after: "") : nil
        }

        let beforeStart = max(0, range.location - Self.contextBefore)
        guard let before = text(of: ref, CFRange(location: beforeStart, length: range.location - beforeStart)) else { return nil }
        var after = ""
        let afterStart = range.location + range.length
        if let count, afterStart < count {
            after = text(of: ref, CFRange(location: afterStart, length: min(Self.contextAfter, count - afterStart))) ?? ""
        }
        return InsertionContext(before: before, after: after)
    }

    /// The frontmost app, its focused element and whether that is secure: the few reads a correction watch repeats.
    func probe() -> FocusProbe {
        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier
        guard let element = elementValue(bounded(AXUIElementCreateSystemWide()), kAXFocusedUIElementAttribute) else {
            return FocusProbe(pid: pid, element: nil, isSecure: false)
        }
        return FocusProbe(
            pid: pid, element: FocusedElement(element), isSecure: isSecure(element, subrole: stringValue(element, kAXSubroleAttribute))
        )
    }

    /// The element's whole text, or nil when the app doesn't give it as a string. Never call on a secure field.
    func fieldValue(of element: FocusedElement) -> String? {
        stringValue(bounded(element.ref), kAXValueAttribute)
    }

    /// A slice by UTF-16 range, from `AXStringForRange` or else the whole value.
    private func text(of element: AXUIElement, _ range: CFRange) -> String? {
        var range = range
        var text: CFTypeRef?
        if let query = AXValueCreate(.cfRange, &range),
           AXUIElementCopyParameterizedAttributeValue(element, kAXStringForRangeParameterizedAttribute as CFString, query, &text) == .success,
           let string = text as? String {
            return string
        }
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value = value as? String else { return nil }
        let units = value.utf16
        guard range.location + range.length <= units.count else { return nil }
        let start = units.index(units.startIndex, offsetBy: range.location)
        let end = units.index(start, offsetBy: range.length)
        return String(units[start..<end])
    }

    @discardableResult
    private func bounded(_ element: AXUIElement) -> AXUIElement {
        AXUIElementSetMessagingTimeout(element, Self.messagingTimeout)
        return element
    }

    private func elementValue(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value, CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
        return bounded(value as! AXUIElement)
    }

    private func stringValue(_ element: AXUIElement, _ attribute: String) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else { return nil }
        return value as? String
    }

    private func title(of window: AXUIElement) -> String? {
        stringValue(window, kAXTitleAttribute).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Secure only when the element says so. An element that cannot be read is not treated as secure, or every app
    /// without Accessibility support would lose its dictation.
    private func isSecure(_ element: AXUIElement, subrole: String?) -> Bool {
        if subrole == kAXSecureTextFieldSubrole as String { return true }
        var protected: CFTypeRef?
        let attribute = NSAccessibility.Attribute.containsProtectedContent.rawValue as CFString
        if AXUIElementCopyAttributeValue(element, attribute, &protected) == .success, let protected = protected as? Bool {
            return protected
        }
        return false
    }

    /// The field's length in UTF-16 units, from `AXNumberOfCharacters` or else the value; nil when the app says neither.
    private func characterCount(_ element: AXUIElement) -> Int? {
        var count: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &count) == .success,
           let count = count as? Int {
            return count
        }
        var value: CFTypeRef?
        if AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
           let value = value as? String {
            return value.utf16.count
        }
        return nil
    }
}
