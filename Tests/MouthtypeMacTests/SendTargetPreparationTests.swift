import Foundation
import Testing

@testable import MouthtypeMac

@Suite struct SendTargetPreparationTests {
    private let claude = "com.anthropic.claudefordesktop"

    private func decide(_ focus: FocusSnapshot, listed: Set<String>) -> Bool {
        SendTargetPreparation.shouldEnable(focus: focus, isListed: { listed.contains($0) })
    }

    @Test func listedAppWithAPidIsEnabled() {
        #expect(decide(FocusSnapshot(pid: 10, bundleID: claude), listed: [claude]))
    }

    @Test func unlistedAppIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: "com.apple.Notes"), listed: [claude]))
    }

    @Test func secureFocusIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: claude, isSecure: true), listed: [claude]))
    }

    @Test(arguments: [nil, 0, -1] as [pid_t?])
    func missingOrNonPositivePidIsNotEnabled(pid: pid_t?) {
        #expect(!decide(FocusSnapshot(pid: pid, bundleID: claude), listed: [claude]))
    }

    @Test func missingBundleIDIsNotEnabled() {
        #expect(!decide(FocusSnapshot(pid: 10, bundleID: nil), listed: [claude]))
    }
}
