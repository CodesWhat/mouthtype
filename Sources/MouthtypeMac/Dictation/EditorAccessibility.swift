import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Foundation
import MouthtypeCore

/// What editor hints may ask of a text field: a selection, a length and a bounded slice. There is deliberately no
/// way to ask for the whole value, so a terminal buffer can't come back through a fallback.
protocol BoundedTextSource {
    func selection() -> NSRange?
    func length() -> Int?
    func slice(location: Int, length: Int) -> String?
}

/// Accessibility reads for editor hints. Everything here is safe to call off the main thread, takes the instant it
/// must finish by, and gives each Accessibility call only what is left of that budget.
enum EditorAccessibility {
    static let contextBefore = 300
    static let contextAfter = 40

    /// The text around the cursor of the focus taken at dictation start. Nil unless that element is a source editor
    /// (not a terminal, not another kind of field), no secure input is active, and the app can answer with a range
    /// read. Nothing is ever read as a whole value.
    static func cursorContext(focus: FocusSnapshot, deadline: ContinuousClock.Instant) -> InsertionContext? {
        guard let ref = readableElement(of: focus),
              EditorHintsSurface.isSourceEditor(role: focus.role, subrole: focus.subrole),
              !isTerminalLabel(copy(ref, kAXDescriptionAttribute, deadline) as? String),
              !isTerminalLabel(copy(ref, kAXTitleAttribute, deadline) as? String) else { return nil }
        return context(from: AccessibilityTextSource(ref: ref, deadline: deadline))
    }

    /// The window's open file, for Xcode.
    static func documentURL(focus: FocusSnapshot, deadline: ContinuousClock.Instant) -> URL? {
        guard let ref = readableElement(of: focus),
              let window = copy(ref, kAXWindowAttribute, deadline), CFGetTypeID(window) == AXUIElementGetTypeID(),
              let document = copy(window as! AXUIElement, kAXDocumentAttribute, deadline) as? String else { return nil }
        return URL(string: document).flatMap { $0.isFileURL ? $0 : nil }
    }

    /// A field whose label calls it a terminal, such as the integrated terminal in VS Code and Cursor, which is a
    /// text area like the editor.
    static func isTerminalLabel(_ label: String?) -> Bool {
        label?.localizedCaseInsensitiveContains("terminal") == true
    }

    /// The cursor window from bounded reads only. A field that won't answer a range read gives nothing.
    static func context(from source: some BoundedTextSource) -> InsertionContext? {
        guard let range = source.selection() else { return nil }
        let count = source.length()
        if range.location == 0 {
            // Terminals report position 0 wherever the cursor is, so 0 is the start only in an empty field.
            return count == 0 ? InsertionContext(before: "", after: "") : nil
        }
        let beforeStart = max(0, range.location - contextBefore)
        guard let before = source.slice(location: beforeStart, length: range.location - beforeStart) else { return nil }
        var after = ""
        let afterStart = range.location + range.length
        if let count, afterStart < count {
            after = source.slice(location: afterStart, length: min(contextAfter, count - afterStart)) ?? ""
        }
        return InsertionContext(before: before, after: after)
    }

    /// The focused element when reading it is allowed: not secure, no secure input, still the app's own element.
    private static func readableElement(of focus: FocusSnapshot) -> AXUIElement? {
        guard !focus.isSecure, !IsSecureEventInputEnabled(), let element = focus.element, let pid = focus.pid,
              focus.focusedOwnerPID == pid, NSWorkspace.shared.frontmostApplication?.processIdentifier == pid else { return nil }
        return element.ref
    }

    /// Seconds one call may take, capped at the usual per-call limit. Nil once the deadline has passed.
    static func budget(until deadline: ContinuousClock.Instant) -> Float? {
        let remaining = deadline - ContinuousClock.now
        guard remaining > .zero else { return nil }
        let seconds = Double(remaining.components.seconds) + Double(remaining.components.attoseconds) / 1e18
        // A timeout of zero means "use the default", so never ask for less than a few milliseconds.
        return max(0.005, min(Float(seconds), AccessibilityFocusReader.messagingTimeout))
    }

    fileprivate static func copy(_ ref: AXUIElement, _ attribute: String, _ deadline: ContinuousClock.Instant) -> CFTypeRef? {
        guard let budget = budget(until: deadline) else { return nil }
        AXUIElementSetMessagingTimeout(ref, budget)
        var value: CFTypeRef?
        return AXUIElementCopyAttributeValue(ref, attribute as CFString, &value) == .success ? value : nil
    }
}

private struct AccessibilityTextSource: BoundedTextSource {
    let ref: AXUIElement
    let deadline: ContinuousClock.Instant

    func selection() -> NSRange? {
        guard let value = EditorAccessibility.copy(ref, kAXSelectedTextRangeAttribute, deadline),
              CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var range = CFRange()
        guard AXValueGetValue(value as! AXValue, .cfRange, &range), range.location >= 0, range.length >= 0 else { return nil }
        return NSRange(location: range.location, length: range.length)
    }

    func length() -> Int? {
        EditorAccessibility.copy(ref, kAXNumberOfCharactersAttribute, deadline) as? Int
    }

    func slice(location: Int, length: Int) -> String? {
        guard let budget = EditorAccessibility.budget(until: deadline) else { return nil }
        AXUIElementSetMessagingTimeout(ref, budget)
        var range = CFRange(location: location, length: length)
        var text: CFTypeRef?
        guard let query = AXValueCreate(.cfRange, &range),
              AXUIElementCopyParameterizedAttributeValue(ref, kAXStringForRangeParameterizedAttribute as CFString, query, &text) == .success
        else { return nil }
        return text as? String
    }
}
