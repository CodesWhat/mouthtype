import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct LivePreviewPreferenceTests {
    @Test func previewIsExplicitlyOptInAndPersistsSeparately() throws {
        let name = "LivePreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set("preserve", forKey: "unrelated")
        #expect(!LivePreviewPreference.isEnabled(defaults))
        LivePreviewPreference.set(true, in: defaults)
        #expect(LivePreviewPreference.isEnabled(defaults))
        LivePreviewPreference.set(false, in: defaults)
        #expect(!LivePreviewPreference.isEnabled(defaults))
        #expect(defaults.string(forKey: "unrelated") == "preserve")
    }
}
