import AVFoundation
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor @Suite struct SetupTests {
    private var ready: SetupReadiness {
        SetupReadiness(microphone: .authorized, accessibility: true, input: .listening,
            speech: .ready(engineID: "parakeet-tdt-v3", loadSeconds: 1), captureReady: true)
    }

    @Test func readinessRequiresEveryWorkingComponent() {
        #expect(ready.isReady)
        var state = ready
        for permission in [AVAuthorizationStatus.notDetermined, .denied, .restricted] {
            state = ready; state.microphone = permission; #expect(!state.isReady)
        }
        state = ready; state.accessibility = false; #expect(!state.isReady)
        for input in [HotkeyHealth.off, .recovering, .secureInputOn] {
            state = ready; state.input = input; #expect(!state.isReady)
        }
        state = ready; state.speech = .loading; #expect(!state.isReady)
        state = ready; state.speech = .failed(message: "Offline"); #expect(!state.isReady)
        state = ready; state.captureReady = false; #expect(!state.isReady)
        state = ready; state.globeConflict = true; #expect(!state.isReady)
    }

    @Test func cardsAdvanceOnlyWhenTheirPrerequisiteActuallyPasses() {
        var state = ready
        state.microphone = .notDetermined
        state.captureReady = false
        state.accessibility = false
        state.speech = .loading
        state.input = .off
        #expect(state.step == .microphone)
        state.microphone = .authorized
        #expect(state.step == .microphone)
        state.captureReady = true
        #expect(state.step == .accessibility)
        state.accessibility = true
        #expect(state.step == .speech)
        state.speech = .failed(message: "Offline")
        #expect(state.step == .speech)
        state.speech = .ready(engineID: "parakeet-tdt-v3", loadSeconds: 1)
        #expect(state.step == .shortcut)
        state.input = .listening
        #expect(state.step == .ready)
    }

    @Test func cardsSkipReadyComponentsAndReturnToLostPrerequisites() {
        var state = ready
        #expect(state.step == .ready)
        state.accessibility = false
        #expect(state.step == .accessibility)
        state.microphone = .denied
        #expect(state.step == .microphone)
        state.microphone = .restricted
        #expect(state.step == .microphone)
        state.microphone = .authorized
        state.accessibility = true
        state.captureReady = false
        #expect(state.step == .microphone)
        state.captureReady = true
        state.input = .recovering
        #expect(state.step == .shortcut)
        state.input = .secureInputOn
        #expect(state.step == .shortcut)
        state.input = .listening
        state.globeConflict = true
        #expect(state.step == .shortcut)
        state.globeConflict = false
        #expect(state.step == .ready)
    }

    @Test func setupReflectsPermissionChangesAndSavedShortcutBehavior() async throws {
        let name = "SetupStateTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let diagnostics = SettingsDiagnostics()
        let model = SetupModel(diagnostics: diagnostics, engine: EngineHost(), defaults: defaults)
        #expect(model.instructions.contains("hold Fn"))
        RecordingModePreference.set(.toggle, in: defaults)
        model.refreshInstructions()
        #expect(model.instructions.contains("press Fn to start"))
        diagnostics.microphoneStatus = .authorized
        diagnostics.accessibilityGranted = true
        diagnostics.hotkeyHealth = .listening
        _ = try await model.microphone.prepare { true }
        #expect(!model.readiness.isReady) // Speech still loading.
        diagnostics.globe = GlobeKeyCheck(action: .showEmoji, fnKeyPresent: true)
        #expect(model.readiness.globeConflict)
        diagnostics.remapChecked = true
        #expect(!model.readiness.globeConflict)
        diagnostics.remapChecked = false
        diagnostics.shortcut = DictationShortcut(keyCode: 61, keyName: "Right Option")
        #expect(!model.readiness.globeConflict)
        diagnostics.hotkeyHealth = .secureInputOn
        #expect(model.inputDetail.contains("password"))
    }

    @Test func setupAppearsOnlyOnceWhenPermissionsNeedSetup() {
        let name = "SetupTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(SetupLaunchPolicy.claimPresentation(defaults: defaults, microphone: .notDetermined, accessibility: false))
        #expect(!SetupLaunchPolicy.claimPresentation(defaults: defaults, microphone: .denied, accessibility: false))
    }

    @Test func permissionObservationDoesNotPromptUntilRequested() {
        let name = "SetupPermissionTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var prompts = 0
        let access = AccessibilityAccess(defaults: defaults, probe: { false }, requestPrompt: { prompts += 1 })
        defer { access.stop() }
        access.start(prompt: false)
        #expect(prompts == 0)
        #expect(!defaults.bool(forKey: AccessibilityAccess.promptedKey))
        access.start()
        access.start()
        #expect(prompts == 1)
    }

    @Test func configuredUsersDoNotGetANewWindowOnUpgrade() {
        let name = "SetupUpgradeTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        #expect(!SetupLaunchPolicy.claimPresentation(defaults: defaults, microphone: .authorized, accessibility: true))
        #expect(defaults.bool(forKey: SetupLaunchPolicy.presentedKey))
        #expect(!SetupLaunchPolicy.claimPresentation(defaults: defaults, microphone: .denied, accessibility: false))
    }
}
