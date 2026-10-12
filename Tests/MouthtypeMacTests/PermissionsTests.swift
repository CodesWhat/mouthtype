import Foundation
import Testing
@testable import MouthtypeMac

@MainActor
private final class GrantBox {
    var value = false
}

@MainActor
@Suite final class AccessibilityAccessTests {
    private let suiteName = "AccessibilityAccessTests-\(UUID().uuidString)"

    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: suiteName)!
    }

    deinit {
        UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        let plist = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Preferences/\(suiteName).plist")
        try? FileManager.default.removeItem(at: plist)
    }

    @Test func publishesTheCurrentStateOnStart() {
        var seen: [Bool] = []
        let access = AccessibilityAccess(defaults: makeDefaults(), probe: { true })
        access.onChange = { seen.append($0) }
        access.start()
        #expect(seen == [true])
        #expect(access.isGranted)
    }

    @Test func pollingPublishesOnlyChanges() {
        let granted = GrantBox()
        var seen: [Bool] = []
        let access = AccessibilityAccess(defaults: makeDefaults(), probe: { granted.value })
        access.onChange = { seen.append($0) }
        #expect(!access.tick())
        #expect(seen.isEmpty)
        granted.value = true
        #expect(access.tick())
        #expect(access.tick())
        #expect(seen == [true])
        access.stop()
    }

    @Test func menuText() {
        #expect(AccessibilityAccess.statusText(granted: true) == "Accessibility: allowed")
        #expect(AccessibilityAccess.statusText(granted: false) == "Accessibility: needed")
    }

    @Test func settingsURLsPointAtTheRightPanes() {
        #expect(AccessibilityAccess.settingsURL.absoluteString == "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
        #expect(GlobeKeyCheck.settingsURL.absoluteString.hasPrefix("x-apple.systempreferences:com.apple.Keyboard"))
    }

    @Test func sectionShowsTheThreeLines() {
        let section = SystemAccessMenuSection()
        section.update(accessibilityGranted: false)
        section.update(hotkeyHealth: .recovering)
        section.update(globe: GlobeKeyCheck(action: .showEmoji, fnKeyPresent: true))
        #expect(section.items.map(\.title) == ["Accessibility: needed", "Hotkey: recovering", "Globe key opens Emoji & Symbols"])
        #expect(section.items[0].action != nil)
        #expect(!section.items[2].isHidden)
        section.update(accessibilityGranted: true)
        section.update(globe: GlobeKeyCheck(action: .doNothing, fnKeyPresent: true))
        #expect(section.items[0].action == nil)
        #expect(section.items[2].isHidden)
    }
}

@Suite struct GlobeKeyCheckTests {
    @Test func usageTypeMapsToTheActionsInParrotsTable() {
        #expect(GlobeKeyCheck.action(forUsageType: 0) == .doNothing)
        #expect(GlobeKeyCheck.action(forUsageType: 1) == .changeInputSource)
        #expect(GlobeKeyCheck.action(forUsageType: 2) == .showEmoji)
        #expect(GlobeKeyCheck.action(forUsageType: 3) == .startDictation)
    }

    @Test func aMissingKeyIsTheOSDefaultAndCountsAsAConflict() {
        let check = GlobeKeyCheck(action: GlobeKeyCheck.action(forUsageType: nil), fnKeyPresent: true)
        #expect(check.action == .showEmoji)
        #expect(check.hasConflict)
        #expect(check.menuText == "Globe key opens Emoji & Symbols")
    }

    @Test func doNothingIsNotAConflict() {
        let check = GlobeKeyCheck(action: .doNothing, fnKeyPresent: true)
        #expect(!check.hasConflict)
        #expect(check.menuText == nil)
    }

    @Test func noFnKeyMeansNoConflictToShow() {
        let check = GlobeKeyCheck(action: .showEmoji, fnKeyPresent: false)
        #expect(!check.hasConflict)
        #expect(check.menuText == nil)
    }

    @Test func otherActionsHaveTheirOwnLine() {
        #expect(GlobeKeyCheck(action: .changeInputSource, fnKeyPresent: true).menuText == "Globe key changes input source")
        #expect(GlobeKeyCheck(action: .startDictation, fnKeyPresent: true).menuText == "Globe key starts Dictation")
    }
}

@MainActor
@Suite struct InputProbeTests {
    @Test func parsesTheProbeArguments() {
        #expect(InputProbe.mode(in: ["Mouthtype"]) == nil)
        #expect(InputProbe.mode(in: ["Mouthtype", "--globe-probe", "30"]) == .globeProbe(seconds: 30))
        #expect(InputProbe.mode(in: ["Mouthtype", "--hotkey-log", "12.5"]) == .hotkeyLog(seconds: 12.5))
        #expect(InputProbe.mode(in: ["Mouthtype", "--globe-probe"]) == .globeProbe(seconds: 30))
        #expect(InputProbe.mode(in: ["Mouthtype", "--hotkey-log", "abc"]) == .hotkeyLog(seconds: 30))
        #expect(InputProbe.mode(in: ["Mouthtype", "--globe-probe", "100000"]) == .globeProbe(seconds: 30))
    }

    @Test func describesAnEventWithTypeKeyCodeFlagsAndFn() {
        let sample = TapSample(kind: .flagsChanged, keyCode: 63, flags: 0x800100, timestamp: 42)
        let line = InputProbe.describe(sample)
        #expect(line.contains("type=flagsChanged"))
        #expect(line.contains("keyCode=63"))
        #expect(line.contains("flags=0x800100"))
        #expect(line.contains("fn=true"))
        #expect(InputProbe.describe(TapSample(kind: .keyDown, keyCode: 0, flags: 0, timestamp: 1)).contains("fn=false"))
    }
}
