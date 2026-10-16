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

    @Test func setupReflectsPermissionChangesAndSavedShortcutBehavior() {
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
        model.captureReady = true
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
