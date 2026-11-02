import ApplicationServices
import Foundation
import Testing
@testable import MouthtypeMac

/// The system-wide focus, which after a click on our panel is not the target's. The recheck must never read it.
@MainActor private final class OtherAppFocus: FocusReading {
    var isSecureInputEnabled = false
    func snapshot() -> FocusSnapshot { FocusSnapshot(pid: 999, role: "AXWindow", focusedOwnerPID: 999) }
    func textBeforeCursor(of element: FocusedElement) -> TextBeforeCursor { .unknown }
}

/// The target app's own focus, separate from the system-wide one the capture reads.
@MainActor private final class TargetApp {
    let element = FocusedElement(AXUIElementCreateApplication(100))
    var frontmost: pid_t? = 100
    var secureInput = false
    var focused: FocusedElement?
    var role = "AXTextArea"
    var subrole: String?
    var range: NSRange? = NSRange(location: 4, length: 9)
    var text: String? = "hi 👩🏽‍💻"
    var writes = 0
    var order: [String] = []

    init() { focused = element }

    var original: SelectedText {
        SelectedText(pid: 100, element: element, range: NSRange(location: 4, length: 9), text: "hi 👩🏽‍💻")
    }

    func editor() -> AccessibilitySelectionEditor {
        AccessibilitySelectionEditor(
            focus: OtherAppFocus(),
            readRange: { _ in
                self.order.append("range")
                return self.range
            },
            readText: { _ in
                self.order.append("text")
                return self.text
            },
            writeText: { _, _ in
                self.writes += 1
                return true
            }, setTimeout: { _, _ in },
            recheck: AcceptRecheck(
                frontmostPID: { self.frontmost }, secureInputEnabled: { self.secureInput },
                focusedElement: { _ in self.focused }, role: { _ in self.role }, subrole: { _ in self.subrole }))
    }
}

@MainActor @Suite struct AcceptRecheckTests {
    @Test func acceptWritesWhenTheSystemWideFocusIsNotTheTargetsButTheAppsOwnFocusMatches() {
        let target = TargetApp()
        #expect(target.editor().replace(target.original, with: "Hello"))
        #expect(target.writes == 1)
    }

    @Test(arguments: ["frontmost", "frontmostNil", "element", "noElement", "role", "range", "rangeNil", "text", "textNil", "secureInput", "subrole"])
    func anyChangeAtAcceptRefusesWithoutWriting(change: String) {
        let target = TargetApp()
        switch change {
        case "frontmost": target.frontmost = 101
        case "frontmostNil": target.frontmost = nil
        case "element": target.focused = FocusedElement(AXUIElementCreateApplication(101))
        case "noElement": target.focused = nil
        case "role": target.role = "AXButton"
        case "range": target.range = NSRange(location: 5, length: 9)
        case "rangeNil": target.range = nil
        case "text": target.text = "Hi 👩🏽‍💻"
        case "textNil": target.text = nil
        case "secureInput": target.secureInput = true
        default: target.subrole = "AXSecureTextField"
        }
        #expect(!target.editor().replace(target.original, with: "Hello"))
        #expect(target.writes == 0)
    }

    @Test func cheapChecksFailBeforeAnyRangeOrTextRead() {
        let target = TargetApp()
        target.frontmost = 101
        #expect(!target.editor().replace(target.original, with: "Hello"))
        #expect(target.order.isEmpty)
    }

    @Test func replacementLengthGuardStillAppliesFirst() {
        let target = TargetApp()
        #expect(!target.editor().replace(target.original, with: ""))
        #expect(!target.editor().replace(target.original, with: String(repeating: "x", count: 16_001)))
        #expect(target.order.isEmpty && target.writes == 0)
    }

    @Test func textFieldAndComboBoxRolesStillPass() {
        for role in ["AXTextField", "AXComboBox"] {
            let target = TargetApp()
            target.role = role
            #expect(target.editor().replace(target.original, with: "Hello"))
        }
    }
}
