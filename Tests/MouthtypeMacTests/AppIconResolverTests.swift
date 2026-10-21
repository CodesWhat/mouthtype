import Foundation
import Testing
@testable import MouthtypeMac

@Suite struct AppIconResolverTests {
    @Test func unknownBundleIDFallsBackToNil() {
        #expect(AppIconResolver.icon(bundleIDs: ["com.example.not-installed-\(UUID().uuidString)"]) == nil)
        #expect(AppIconResolver.icon(bundleIDs: []) == nil)
    }

    @Test func installedAppResolvesAndCaches() {
        let first = AppIconResolver.icon(bundleIDs: ["com.apple.finder"])
        #expect(first != nil)
        #expect(AppIconResolver.cachedIcon(bundleIDs: ["com.apple.finder"]) === first)
    }
}
