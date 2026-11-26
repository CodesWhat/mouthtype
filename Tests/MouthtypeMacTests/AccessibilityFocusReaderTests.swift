import AppKit
import ApplicationServices
import Foundation
import MouthtypeCore
import Testing
@testable import MouthtypeMac

/// Drives `AccessibilityFocusReader` over canned Accessibility answers, so the role, secure-field and ownership reads run
/// without Accessibility permission. Elements are application refs for made-up pids, compared by `CFEqual` as in the app.
private final class FakeAccessibility: AccessibilityBackend, @unchecked Sendable {
    struct Key: Hashable {
        let pid: pid_t
        let attribute: String
    }

    var frontmostApplication: (pid: pid_t, bundleID: String?, name: String?)? = (1000, "com.example.Editor", "Editor")
    var isSecureInputEnabled = false
    var values: [Key: CFTypeRef] = [:]
    var errors: [Key: AXError] = [:]
    var ranged: [Key: String] = [:]
    var settable: [Key: Bool] = [:]
    var ownerPids: [pid_t: pid_t] = [:]

    static func element(_ pid: pid_t) -> AXUIElement { AXUIElementCreateApplication(pid) }

    private func key(_ element: AXUIElement, _ attribute: String) -> Key {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return Key(pid: pid, attribute: attribute)
    }

    func set(_ pid: pid_t, _ attribute: String, _ value: CFTypeRef) { values[Key(pid: pid, attribute: attribute)] = value }

    func systemWide() -> AXUIElement { Self.element(1) }
    func application(pid: pid_t) -> AXUIElement { Self.element(pid) }
    func setTimeout(_ element: AXUIElement, _ seconds: Float) {}

    func copyAttribute(_ element: AXUIElement, _ attribute: String) -> (AXError, CFTypeRef?) {
        let key = key(element, attribute)
        if let error = errors[key] { return (error, nil) }
        guard let value = values[key] else { return (.noValue, nil) }
        return (.success, value)
    }

    func copyParameterized(_ element: AXUIElement, _ attribute: String, _ parameter: CFTypeRef) -> (AXError, CFTypeRef?) {
        guard let text = ranged[key(element, attribute)] else { return (.attributeUnsupported, nil) }
        return (.success, text as CFString)
    }

    func pid(of element: AXUIElement) -> (AXError, pid_t) {
        var pid: pid_t = 0
        AXUIElementGetPid(element, &pid)
        return (.success, ownerPids[pid] ?? pid)
    }

    func isSettable(_ element: AXUIElement, _ attribute: String) -> (AXError, Bool) {
        guard let value = settable[key(element, attribute)] else { return (.attributeUnsupported, false) }
        return (.success, value)
    }
}

private func axRange(_ location: Int, _ length: Int = 0) -> CFTypeRef {
    var range = CFRange(location: location, length: length)
    return AXValueCreate(.cfRange, &range)!
}

@MainActor @Suite struct AccessibilityFocusReaderTests {
    private let field: pid_t = 2000
    private let focused = kAXFocusedUIElementAttribute

    private func make() -> (FakeAccessibility, AccessibilityFocusReader) {
        let fake = FakeAccessibility()
        return (fake, AccessibilityFocusReader(backend: fake))
    }

    private func focus(_ fake: FakeAccessibility, role: String = "AXTextField", subrole: String? = nil) {
        fake.set(1, focused, FakeAccessibility.element(field))
        fake.set(field, kAXRoleAttribute, role as CFString)
        if let subrole { fake.set(field, kAXSubroleAttribute, subrole as CFString) }
    }

    @Test func snapshotWithNoFocusedElementKeepsTheFrontmostApp() {
        let (fake, reader) = make()
        fake.set(1000, kAXFocusedWindowAttribute, FakeAccessibility.element(3000))
        fake.set(3000, kAXTitleAttribute, "Notes" as CFString)
        let snapshot = reader.snapshot()
        #expect(snapshot.pid == 1000)
        #expect(snapshot.bundleID == "com.example.Editor")
        #expect(snapshot.appName == "Editor")
        #expect(snapshot.element == nil)
        #expect(snapshot.windowTitle == "Notes")
    }

    @Test func snapshotReadsRoleSubroleAndWindowTitle() {
        let (fake, reader) = make()
        focus(fake)
        fake.set(field, kAXWindowAttribute, FakeAccessibility.element(3000))
        fake.set(3000, kAXTitleAttribute, "Draft" as CFString)
        let snapshot = reader.snapshot()
        #expect(snapshot.role == "AXTextField")
        #expect(snapshot.isSecure == false)
        #expect(snapshot.readsFailed == false)
        #expect(snapshot.windowTitle == "Draft")
        #expect(snapshot.element == FocusedElement(FakeAccessibility.element(field)))
        #expect(snapshot.isConfirmedNormalField)
    }

    @Test func secureSubroleMarksTheFieldSecure() {
        let (fake, reader) = make()
        focus(fake, subrole: kAXSecureTextFieldSubrole as String)
        let snapshot = reader.snapshot()
        #expect(snapshot.isSecure)
        #expect(snapshot.isConfirmedNormalField == false)
    }

    @Test func protectedContentMarksTheFieldSecure() {
        let (fake, reader) = make()
        focus(fake)
        fake.set(field, NSAccessibility.Attribute.containsProtectedContent.rawValue, kCFBooleanTrue)
        #expect(reader.snapshot().isSecure)
    }

    @Test func aFailedReadIsNotTreatedAsSecureButIsFlagged() {
        let (fake, reader) = make()
        focus(fake)
        fake.errors[.init(pid: field, attribute: kAXSubroleAttribute)] = .cannotComplete
        let snapshot = reader.snapshot()
        #expect(snapshot.isSecure == false)
        #expect(snapshot.readsFailed)
        #expect(snapshot.isConfirmedNormalField == false)
    }

    @Test func unsupportedAttributesAreAnswersNotFailures() {
        let (fake, reader) = make()
        focus(fake)
        fake.errors[.init(pid: field, attribute: kAXSubroleAttribute)] = .attributeUnsupported
        #expect(reader.snapshot().readsFailed == false)
    }

    @Test func staticTextIsSettableOnlyWhenTheValueOrSelectionCanBeSet() {
        let (fake, reader) = make()
        focus(fake, role: "AXStaticText")
        #expect(reader.snapshot().isTextSettable == nil)
        fake.settable[.init(pid: field, attribute: kAXValueAttribute)] = false
        #expect(reader.snapshot().isTextSettable == false)
        fake.settable[.init(pid: field, attribute: kAXSelectedTextAttribute)] = true
        let snapshot = reader.snapshot()
        #expect(snapshot.isTextSettable == true)
        #expect(snapshot.isConfirmedNormalField)
    }

    @Test func elementOwnedByAnotherProcessResolvesItsApplicationThroughTheWindow() {
        let (fake, reader) = make()
        focus(fake)
        fake.ownerPids[field] = 4000
        fake.set(field, kAXTopLevelUIElementAttribute, FakeAccessibility.element(3000))
        fake.set(3000, kAXParentAttribute, FakeAccessibility.element(5000))
        fake.set(5000, kAXRoleAttribute, kAXApplicationRole as CFString)
        let snapshot = reader.snapshot()
        #expect(snapshot.focusedOwnerPID == 4000)
        #expect(snapshot.focusedApplicationPID == 5000)
        #expect(snapshot.focusOwnerDiffersFromFrontmost)
    }

    @Test func ownershipWithoutReadableAncestryIsNotAMismatch() {
        let (fake, reader) = make()
        focus(fake)
        fake.ownerPids[field] = 4000
        let snapshot = reader.snapshot()
        #expect(snapshot.focusedOwnerPID == 4000)
        #expect(snapshot.focusedApplicationPID == nil)
        #expect(snapshot.focusOwnerDiffersFromFrontmost == false)
    }

    @Test func selectionSnapshotAsksTheAppWhenTheSystemWideElementIsEmpty() {
        let (fake, reader) = make()
        fake.set(1000, kAXFocusedUIElementAttribute, FakeAccessibility.element(field))
        fake.set(field, kAXRoleAttribute, "AXTextArea" as CFString)
        #expect(reader.snapshot().element == nil)
        let snapshot = reader.selectionSnapshot()
        #expect(snapshot.element == FocusedElement(FakeAccessibility.element(field)))
        #expect(snapshot.role == "AXTextArea")
    }

    @Test func recheckReadsOnlyWhatTheGuardsCompare() {
        let (fake, reader) = make()
        focus(fake, subrole: kAXSecureTextFieldSubrole as String)
        let snapshot = reader.recheck()
        #expect(snapshot.pid == 1000)
        #expect(snapshot.isSecure)
        #expect(snapshot.role == nil)
        #expect(snapshot.element == FocusedElement(FakeAccessibility.element(field)))
    }

    @Test func recheckWithNoFocusedElementReturnsTheApplication() {
        let (_, reader) = make()
        let snapshot = reader.recheck()
        #expect(snapshot.pid == 1000)
        #expect(snapshot.element == nil)
    }

    @Test func secureInputComesFromTheBackend() {
        let (fake, reader) = make()
        #expect(reader.isSecureInputEnabled == false)
        fake.isSecureInputEnabled = true
        #expect(reader.isSecureInputEnabled)
    }

    // MARK: Text reads

    private func element() -> FocusedElement { FocusedElement(FakeAccessibility.element(field)) }

    @Test func textBeforeCursorIsUnknownWithoutARange() {
        let (_, reader) = make()
        #expect(reader.textBeforeCursor(of: element()) == .unknown)
    }

    @Test func cursorAtZeroIsTheStartOnlyInAnEmptyField() {
        let (fake, reader) = make()
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(0))
        fake.set(field, kAXNumberOfCharactersAttribute, 0 as CFNumber)
        #expect(reader.textBeforeCursor(of: element()) == .start)
        fake.set(field, kAXNumberOfCharactersAttribute, 12 as CFNumber)
        #expect(reader.textBeforeCursor(of: element()) == .unknown)
    }

    @Test func textBeforeCursorUsesTheRangeStringWhenTheAppAnswersIt() {
        let (fake, reader) = make()
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(5))
        fake.ranged[.init(pid: field, attribute: kAXStringForRangeParameterizedAttribute)] = "lo"
        #expect(reader.textBeforeCursor(of: element()) == .character("o"))
    }

    @Test func textBeforeCursorFallsBackToTheWholeValue() {
        let (fake, reader) = make()
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(5))
        fake.set(field, kAXValueAttribute, "hello world" as CFString)
        #expect(reader.textBeforeCursor(of: element()) == .character("o"))
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(99))
        #expect(reader.textBeforeCursor(of: element()) == .unknown)
    }

    @Test func insertionContextCutsTextAroundTheCursor() {
        let (fake, reader) = make()
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(5))
        fake.set(field, kAXNumberOfCharactersAttribute, 11 as CFNumber)
        fake.set(field, kAXValueAttribute, "hello world" as CFString)
        #expect(reader.insertionContext(of: element()) == InsertionContext(before: "hello", after: " world"))
    }

    @Test func insertionContextIsEmptyInAnEmptyFieldAndNilWhenTheStartIsUntrustworthy() {
        let (fake, reader) = make()
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(0))
        fake.set(field, kAXNumberOfCharactersAttribute, 0 as CFNumber)
        #expect(reader.insertionContext(of: element()) == InsertionContext(before: "", after: ""))
        fake.set(field, kAXNumberOfCharactersAttribute, 4 as CFNumber)
        #expect(reader.insertionContext(of: element()) == nil)
    }

    @Test func readFieldReportsValueLengthAndSelection() {
        let (fake, reader) = make()
        fake.set(field, kAXValueAttribute, "hello" as CFString)
        fake.set(field, kAXSelectedTextRangeAttribute, axRange(1, 2))
        let reading = reader.readField(of: element())
        #expect(reading.value == "hello")
        #expect(reading.length == 5)
        #expect(reading.selection == NSRange(location: 1, length: 2))
        #expect(reading.isComplete)
    }

    @Test func websiteHostReaderStandsDownUnderSecureInput() {
        let (fake, reader) = make()
        focus(fake)
        var snapshot = reader.snapshot()
        snapshot.pid = 2000
        snapshot.bundleID = "com.apple.Safari"
        fake.isSecureInputEnabled = true
        #expect(reader.websiteHostReader(for: snapshot) == nil)
    }
}
