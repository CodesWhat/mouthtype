import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// The Settings modal's General, Mac, Health and Advanced pages. The redesign draws its own popups and switches, so there are no AppKit
/// controls to count offscreen. Each page is checked by the identifiers and titles in its source, then rendered in light and dark.
@MainActor @Suite(.serialized) struct ModalPagesTests {
    private func source(_ files: [String]) throws -> String {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = root.appendingPathComponent("Sources/MouthtypeMac/Settings")
        return try files.map { try String(contentsOf: directory.appendingPathComponent($0 + ".swift"), encoding: .utf8) }.joined()
    }

    private func makeModel() throws -> (SettingsModel, () -> Void) {
        let name = "ModalPages-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        FontRegistry.registerBundledFonts()
        return (SettingsModel(defaults: defaults), { defaults.removePersistentDomain(forName: name) })
    }

    private func actions() -> SettingsActions {
        let state = SettingsDiagnostics()
        state.engineStatus = "Parakeet TDT v3 ready"
        return SettingsActions(cleaner: ModalCleaner(), diagnostics: state, updater: AppUpdater(driver: ModalUpdateDriver(), activity: { .idle }))
    }

    @Test func generalHoldsShortcutRecordingBehaviorAndTheRecordingSwitches() throws {
        let text = try source(["SettingsGeneralPage", "LivePreviewSettingsRow"])
        for needle in [
            "settings-shortcut", "settings-recording-mode", "settings-sounds",
            "settings-live-preview", "settings-quiet-audio", "\"Shortcut\"", "\"Recording behavior\"", "\"Recording sounds\"",
            "\"Live words\"", "\"Quiet other audio\"",
        ] {
            #expect(text.contains(needle), "General is missing \(needle)")
        }
    }

    @Test func microphoneHoldsThePickerRefreshAndPriorityList() throws {
        let text = try source(["SettingsGeneralPage", "MicrophoneSettingsSection"])
        for needle in [
            "microphonePage", "settings-microphone", "settings-microphone-refresh", "settings-microphone-priority", "Microphone priority list",
        ] {
            #expect(text.contains(needle), "Microphone is missing \(needle)")
        }
    }

    @Test func macHoldsLaunchAtLoginAndUpdates() throws {
        let text = try source(["SettingsGeneralPage", "SettingsMacPage"])
        for needle in ["settings-launch-at-login", "settings-auto-updates", "settings-check-updates", "\"Launch at login\"", "Check for Updates…"] {
            #expect(text.contains(needle), "Mac is missing \(needle)")
        }
    }

    @Test func healthKeepsEveryDiagnosticAndAction() throws {
        let text = try source(["SettingsDiagnosticsView"])
        for needle in [
            "settings-setup", "Speech recognition", "Retry model", "Download…", "Cancel download", "Microphone Settings…",
            "Accessibility Settings…", "Shortcut listener", "Change shortcut…", "How dictation works", "Keyboard Settings…",
            "Edit dictionary…", "Edit phrases file…", "Refresh status",
        ] {
            #expect(text.contains(needle), "Health is missing \(needle)")
        }
        #expect(!text.contains("AudioRetentionSection"), "audio retention moved to Advanced")
    }

    @Test func advancedHoldsEveryOptionTheReadmeMovesThere() throws {
        let text = try source(["SettingsAdvancedPage", "AudioRetentionSection", "SendAfterInsertSection"])
        for needle in [
            "PRESS RETURN AFTER INSERTING", "settings-send-after-insert-add", "settings-send-after-insert-remove",
            "Boost saved words", "Learn from my corrections", "Remove fillers", "Spoken commands and lists",
            "Format numbers", "Lowercase sentence starts", "Drop the final full stop", "Split long pastes", "Keep finished audio for",
            "Dictionary file", "Remap Fn to hide the emoji picker", "settings-audio-age", "settings-audio-size", "settings-remap-fn",
            "setBoostSavedWords", "setLearnCorrections", "setChunks", "toggleRemap", "editDictionary",
        ] {
            #expect(text.contains(needle), "Advanced is missing \(needle)")
        }
    }

    @Test(arguments: ["light", "dark"])
    func everyModalPageRendersWithoutTruncatingText(appearance: String) throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        model.setAdvancedOptions(true)
        for page in SettingsModalPage.allCases {
            model.modalPage = page
            let (view, _) = SettingsRender.hostModal(model: model, actions: actions(), dark: appearance == "dark")
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            #expect(bitmap.pixelsWide >= 760 && bitmap.pixelsHigh >= 540)
            try SettingsRender.save(bitmap, name: "modal-\(page.rawValue)-\(appearance)")
        }
    }

    @Test(arguments: [false, true])
    func whisperLanguageSettingsRenderWithTheDownloadNotice(dark: Bool) throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        model.setDictationLanguage(.explicit(.japanese))
        model.modalPage = .general
        #expect(model.dictationLanguage.usesWhisper)
        #expect(model.dictationLanguage.detailText.contains("1.6 GB"))
        let bitmap = try SettingsRender.renderModal(model: model, actions: actions(), dark: dark)
        #expect(bitmap.pixelsWide >= 760 && bitmap.pixelsHigh >= 540)
        try SettingsRender.save(bitmap, name: "general-whisper-\(dark ? "dark" : "light")")
    }

    @Test func microphoneShowsThePriorityListOnceItIsChosen() throws {
        let name = "ModalPriority-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        FontRegistry.registerBundledFonts()
        let devices = [
            MicrophoneDevice(uid: "usb", name: "USB Microphone", input: .init(sampleRate: 48_000, channels: 1, id: 1)),
            MicrophoneDevice(uid: "mac", name: "MacBook Pro Microphone", input: .init(sampleRate: 48_000, channels: 1, id: 2)),
        ]
        let microphone = MicrophoneSettingsModel(defaults: defaults, devices: { devices }, defaultInput: { 2 })
        let model = SettingsModel(defaults: defaults, microphone: microphone)
        model.setAdvancedOptions(true)
        model.modalPage = .microphone
        #expect(microphone.choice == .systemDefault && microphone.priority == nil)
        microphone.choose(.priorityList)
        microphone.addPriority(uid: "mac")
        #expect(microphone.choice == .priorityList)
        #expect(microphone.priority?.devices.map(\.uid).sorted() == ["mac", "usb"])
        for dark in [false, true] {
            let (view, _) = SettingsRender.hostModal(model: model, actions: actions(), dark: dark)
            let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
            view.cacheDisplay(in: view.bounds, to: bitmap)
            try SettingsRender.save(bitmap, name: "modal-microphone-priority-\(dark ? "dark" : "light")")
        }
    }

    @Test func advancedSwitchesWriteTheSameSettingsAsBefore() throws {
        let (model, cleanup) = try makeModel()
        defer { cleanup() }
        model.setBoostSavedWords(true); #expect(model.boostSavedWords)
        model.setLearnCorrections(false); #expect(!model.learnCorrections)
        model.setFillers(false); #expect(!model.cleanup.fillers)
        model.setLowercaseStarts(true); #expect(model.cleanup.style.capitalisation == .lowercase)
        model.setDropFinalStop(true); #expect(model.cleanup.style.endingPunctuation == .dropFinalFullStop)
        let terminal = try #require(PasteSettings.supportedTerminals.first)
        model.setChunks(true, bundleID: terminal.bundleID); #expect(model.chunkedTerminals.contains(terminal.bundleID))
        model.setAudioRetentionAge(.days14); #expect(model.audioRetention.age == .days14)
    }
}

@MainActor private final class ModalCleaner: CleanupModelManaging {
    let state = CleanerState.absent
    let modelName = "Fast cleanup"
    let downloadSizeMB = 600
    func start() {}
    func levelChanged() {}
    func startDownload() {}
    func cancelDownload() {}
    nonisolated func recordingStarted() {}
    func readiness(waitingUpTo limit: Duration) async -> SmartCleanerInfo? { nil }
    func run(_ request: SmartCleanupRequest) async -> SmartCleanupResult { fatalError("Modal page tests do not run cleanup") }
}

@MainActor private final class ModalUpdateDriver: UpdateDriving {
    weak var delegate: (any UpdateDriverDelegate)?
    var onChange: (() -> Void)?
    var canCheckForUpdates = true
    var automaticallyChecksForUpdates = false
    func start() throws {}
    func checkForUpdates() {}
}
