import AppKit
import AVFoundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct UsabilityMenuTests {
    @Test func aPermissionChangeIsReportedWithoutRelaunching() {
        var status = AVAuthorizationStatus.denied
        let section = MicrophoneMenuSection(status: { status })
        var changes: [AVAuthorizationStatus] = []
        section.onStatusChanged = { changes.append($0) }
        section.refresh()
        status = .authorized
        section.refresh()
        section.refresh()
        #expect(changes == [.authorized])
        #expect(!section.items[0].isEnabled)
    }

    @Test func deniedMicrophoneAccessHasASettingsAction() {
        let section = MicrophoneMenuSection(status: { .denied })
        #expect(section.items[0].isEnabled)
        #expect(section.items[0].action != nil)
        let allowed = MicrophoneMenuSection(status: { .authorized })
        #expect(!allowed.items[0].isEnabled && allowed.items[0].action == nil)
    }

    @Test func helpExplainsTheGesturesAndLocalStorage() {
        let section = HelpMenuSection(onShow: {})
        #expect(section.items.first?.title == "How to Use Mouthtype…")
        for text in ["hold Fn", "double-tap", "Fn+Space", "Esc", "90 days", "2 GB", "on this Mac"] {
            #expect(HelpMenuSection.instructions.contains(text))
        }
    }

    @Test func retryAppearsOnlyAfterEngineFailure() async {
        let host = EngineHost(engineID: "missing")
        let section = EngineRetryMenuSection(host: host)
        #expect(section.items[0].isHidden)
        await host.load()
        section.refresh()
        #expect(!section.items[0].isHidden && section.items[0].isEnabled)
        #expect(section.items[0].title == "Retry Speech Model")
    }
}
