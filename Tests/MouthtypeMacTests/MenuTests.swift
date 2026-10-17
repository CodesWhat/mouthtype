import AppKit
import AVFAudio
import Foundation
import ServiceManagement
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
private final class FakeLoginService: LoginItemService {
    var status: SMAppService.Status
    var registered = 0
    var unregistered = 0
    var settingsOpened = 0
    var statusAfterRegister: SMAppService.Status = .enabled

    init(status: SMAppService.Status) {
        self.status = status
    }

    func register() throws {
        registered += 1
        status = statusAfterRegister
    }

    func unregister() throws {
        unregistered += 1
        status = .notRegistered
    }

    func openSystemSettings() { settingsOpened += 1 }
}

@MainActor
@Suite struct LoginItemTests {
    @Test func statusMapsToTheCheckbox() {
        #expect(LoginItem.menuState(for: .enabled) == .on)
        #expect(LoginItem.menuState(for: .requiresApproval) == .mixed)
        #expect(LoginItem.menuState(for: .notRegistered) == .off)
        #expect(LoginItem.menuState(for: .notFound) == .off)
        #expect(LoginItem(service: FakeLoginService(status: .enabled)).menuState == .on)
    }

    @Test func clickingWhenOffRegisters() {
        let service = FakeLoginService(status: .notRegistered)
        let item = LoginItem(service: service)
        item.toggle()
        #expect(service.registered == 1 && service.unregistered == 0 && service.settingsOpened == 0)
        #expect(item.menuState == .on)
    }

    @Test func clickingWhenOnUnregisters() {
        let service = FakeLoginService(status: .enabled)
        let item = LoginItem(service: service)
        item.toggle()
        #expect(service.unregistered == 1 && service.registered == 0)
        #expect(item.menuState == .off)
    }

    @Test func registeringIntoApprovalOpensLoginItemsSettings() {
        let service = FakeLoginService(status: .notRegistered)
        service.statusAfterRegister = .requiresApproval
        let item = LoginItem(service: service)
        item.toggle()
        #expect(service.registered == 1 && service.settingsOpened == 1)
        #expect(item.menuState == .mixed)
    }

    @Test func clickingWhileWaitingForApprovalOnlyOpensSettings() {
        let service = FakeLoginService(status: .requiresApproval)
        LoginItem(service: service).toggle()
        #expect(service.settingsOpened == 1 && service.registered == 0 && service.unregistered == 0)
    }
}

@MainActor
@Suite struct StatusIconTests {
    @Test func everyGlyphLoadsAsATemplateWithBothRepresentations() throws {
        for icon in StatusIcon.allCases {
            let image = try #require(icon.image, "\(icon.glyphName) did not load")
            #expect(image.isTemplate)
            #expect(image.size == NSSize(width: 16, height: 15))
            let pixels = image.representations.map { [$0.pixelsWide, $0.pixelsHigh] }
            #expect(pixels == [[16, 15], [32, 30]], "\(icon.glyphName)")
        }
        #expect(Set(StatusIcon.allCases.map(\.glyphName)).count == 4)
    }

    @Test func aStatusIconCanBePinnedFromTheCommandLine() {
        #expect(StatusIcon.pinned(in: ["Mouthtype", "--status-icon", "unavailable"]) == .unavailable)
        #expect(StatusIcon.pinned(in: ["Mouthtype", "--status-icon", "bogus"]) == nil)
        #expect(StatusIcon.pinned(in: ["Mouthtype", "--status-icon"]) == nil)
        #expect(StatusIcon.pinned(in: ["Mouthtype"]) == nil)
    }

    @Test func eachStateDrawsDifferently() throws {
        let bitmaps = try StatusIcon.allCases.map { icon in
            let rep = try #require(icon.image?.representations.first as? NSBitmapImageRep)
            return rep.representation(using: .png, properties: [:])
        }
        #expect(Set(bitmaps).count == 4)
    }

    @Test func phaseMapsToTheIconWhenEverythingWorks() {
        func icon(_ phase: DictationController.Phase) -> StatusIcon {
            StatusIcon.resolve(phase: phase, engineFailed: false, microphoneAllowed: true, accessibilityGranted: true)
        }
        #expect(icon(.idle) == .idle)
        #expect(icon(.recording) == .recording)
        #expect(icon(.processing) == .processing)
    }

    @Test func aFailedEngineOrMissingAccessMeansUnavailable() {
        #expect(StatusIcon.resolve(phase: .idle, engineFailed: true, microphoneAllowed: true, accessibilityGranted: true) == .unavailable)
        #expect(StatusIcon.resolve(phase: .idle, engineFailed: false, microphoneAllowed: false, accessibilityGranted: true) == .unavailable)
        #expect(StatusIcon.resolve(phase: .idle, engineFailed: false, microphoneAllowed: true, accessibilityGranted: false) == .unavailable)
    }
}

@MainActor
@Suite struct SoundTests {
    @Test func clickReplacesTheSystemCueNames() {
        #expect(ClickSoundPlayer.startName == "start")
        #expect(ClickSoundPlayer.stopName == "stop")
        #expect(ClickSoundPlayer.lockName == "lock")
        #expect(ClickSoundPlayer.errorName == "error")
    }

    @Test func allFourClickCuesDecodeWithoutLooping() throws {
        for name in [ClickSoundPlayer.startName, ClickSoundPlayer.stopName, ClickSoundPlayer.lockName, ClickSoundPlayer.errorName] {
            let url = try #require(ClickSoundPlayer.cueURL(name))
            let player = try AVAudioPlayer(contentsOf: url)
            #expect(player.duration > 0 && player.duration < 0.4)
            #expect(player.numberOfLoops == 0)
        }
        #expect(Set([ClickSoundPlayer.startName, ClickSoundPlayer.stopName, ClickSoundPlayer.errorName]).count == 3)
        let suite = "SoundTests-\(UUID().uuidString)"
        defer { UserDefaults(suiteName: suite)?.removePersistentDomain(forName: suite) }
        #expect(ClickSoundPlayer(defaults: UserDefaults(suiteName: suite)!).loadedAll)
    }

    @Test func quietDelayUsesDecodedStartCueAndRespectsDisabledSounds() throws {
        let suite = "SoundQuietTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cue = try AVAudioPlayer(contentsOf: #require(ClickSoundPlayer.cueURL(ClickSoundPlayer.startName)))
        let player = ClickSoundPlayer(defaults: defaults)
        #expect(player.startCueDuration == cue.duration)
        #expect(player.startCueDuration > 0)
        #expect(!player.isStartCuePlaying)
        SoundPreference.set(false, in: defaults)
        #expect(player.startCueDuration == 0)
    }

    @Test func soundsDefaultToOnAndFollowTheSwitch() {
        let suite = "SoundPrefTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(SoundPreference.isEnabled(defaults))
        SoundPreference.set(false, in: defaults)
        #expect(!SoundPreference.isEnabled(defaults))
        #expect(defaults.object(forKey: "soundsEnabled") as? Bool == false)
    }
}

@MainActor
@Suite struct HistoryMenuTests {
    private func makeStore() throws -> (TranscriptStore, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-menu-\(UUID().uuidString)")
        return (try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite")), dir)
    }

    @Test func statsLineFormats() {
        #expect(HistoryMenuSection.statsLine(nil) == "No dictations yet")
        let zero = StatsSummary(wordsToday: 0, recentWPM: 0, currentStreakDays: 0, longestStreakDays: 0)
        #expect(HistoryMenuSection.statsLine(zero) == "No dictations yet")
        let full = StatsSummary(wordsToday: 312, recentWPM: 148.2, currentStreakDays: 4, longestStreakDays: 9)
        #expect(HistoryMenuSection.statsLine(full) == "312 words today \u{00B7} 148 WPM \u{00B7} 4 day streak")
        let one = StatsSummary(wordsToday: 1, recentWPM: 90, currentStreakDays: 0, longestStreakDays: 3)
        #expect(HistoryMenuSection.statsLine(one) == "1 word today \u{00B7} 90 WPM")
    }

    @Test func titlesShortenAtAWordBoundaryWithNoEllipsis() {
        #expect(HistoryMenuSection.shortened("short one") == "short one")
        let long = String(repeating: "word ", count: 30)
        let title = HistoryMenuSection.shortened(long)
        #expect(!title.contains("\u{2026}") && title.count <= 50 && title == "word word word word word word word word word word")
        #expect(HistoryMenuSection.shortened("line one\n\nline   two") == "line one line two")
        // Lands exactly on a boundary, and cuts mid-word back to the last whole word.
        #expect(HistoryMenuSection.shortened("abcd efgh ijkl", limit: 9) == "abcd efgh")
        #expect(HistoryMenuSection.shortened("abcd efgh ijkl", limit: 11) == "abcd efgh")
        // A first word longer than the limit has no boundary, so it is cut at the limit.
        #expect(HistoryMenuSection.shortened("supercalifragilistic is long", limit: 10) == "supercalif")
    }

    @Test func listsTheLastFiveNewestFirstAndCopiesFullText() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let base = Date()
        for i in 0..<7 {
            let id = try store.begin(DictationStart(startedAt: base.addingTimeInterval(Double(i))))
            try store.recordInsertion(id, InsertionRecord(finalText: "dictation number \(i) " + String(repeating: "x", count: 80)))
        }
        // A secure discard leaves empty text and must not show up.
        let secure = try store.begin(DictationStart(startedAt: base.addingTimeInterval(20)))
        try store.recordInsertion(secure, InsertionRecord(finalText: ""))

        let section = HistoryMenuSection(store: store, now: { base })
        let parent = try #require(section.items.first)
        #expect(parent.title == "Recent Dictations")
        let items = try #require(parent.submenu?.items)
        #expect(items.count == 1 + HistoryMenuSection.recentCount)
        #expect(items[0].isEnabled == false && items[0].title.contains("words today"))
        #expect(items[1].title.hasPrefix("dictation number 6"))
        #expect(items[5].title.hasPrefix("dictation number 2"))
        #expect(items[1].title == "dictation number 6" && !items[1].title.contains("\u{2026}"))
        let full = try #require(items[1].representedObject as? String)
        #expect(full.hasPrefix("dictation number 6") && full.count > 80)
        #expect(items[1].toolTip == full)
    }

    @Test func recentIsHiddenWhenThereAreNone() throws {
        let (store, dir) = try makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let section = HistoryMenuSection(store: store)
        #expect(section.items.isEmpty)
    }

    @Test func unavailableHistoryIsHiddenAndReportsDiagnostics() {
        var error: String?
        let section = HistoryMenuSection(store: nil, onError: { error = $0 })
        #expect(section.items.isEmpty)
        #expect(error != nil)
    }
}

@MainActor
@Suite struct ActionsMenuTests {
    @Test func aChosenDictationComboTakesPrecedenceOverPasteLast() {
        let suite = "ActionsMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        ShortcutSettings.save(DictationShortcut(keyCode: 9, modifiers: CGEventFlags.maskCommand.rawValue | CGEventFlags.maskControl.rawValue, keyName: "V"), in: defaults)
        let section = ActionsMenuSection(defaults: defaults, onPasteLast: {}, onCopyLast: {})
        #expect(section.items[0].keyEquivalent.isEmpty)
        #expect(section.items[1].keyEquivalent == "c")
        #expect(section.items[0].action != nil)
        ShortcutSettings.save(nil, in: defaults)
        section.refresh()
        #expect(section.items[0].keyEquivalent == "v")
    }
    @Test func dailyActionsKeepShortcutsAndSoundPreference() {
        let suite = "ActionsMenuTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let section = ActionsMenuSection(defaults: defaults, onPasteLast: {}, onCopyLast: {})
        let titles = section.items.map(\.title)
        #expect(titles == ["Paste Last", "Copy Last"])
        #expect(section.items[0].keyEquivalent == "v" && section.items[0].keyEquivalentModifierMask == [.command, .control])
        #expect(section.items[1].keyEquivalent == "c" && section.items[1].keyEquivalentModifierMask == [.command, .control])
        #expect(SoundPreference.isEnabled(defaults))
    }

    @Test func globalShortcutsUseCommandControlVAndC() {
        #expect(GlobalShortcuts.Shortcut.pasteLast.keyCode == 9)
        #expect(GlobalShortcuts.Shortcut.copyLast.keyCode == 8)
        #expect(GlobalShortcuts.Shortcut.pasteLast.modifiers == 0x100 | 0x1000)
        #expect(GlobalShortcuts.Shortcut.copyLast.modifiers == 0x100 | 0x1000)
    }
}
