import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct AudioRetentionTests {
    @Test func balancedRetainsExistingAgeAndSizeDefaults() {
        let policy = AudioRetentionPolicy()
        let now = Date(timeIntervalSince1970: 1_000)
        #expect(policy.age == .days90 && policy.size == .gb2)
        #expect(policy.expiration(from: now) == now.addingTimeInterval(AudioArchive.defaultRetention))
        #expect(policy.maximumBytes == AudioArchive.defaultMaxTotalBytes)
    }

    @Test func noAgeLimitStillHasAStorageCap() {
        let policy = AudioRetentionPolicy(age: .noAgeLimit, size: .gb10)
        #expect(policy.expiration(from: Date()) == nil)
        #expect(policy.maximumBytes == 10 * 1_024 * 1_024 * 1_024)
        #expect(policy.cutoff(at: Date()) == Date.distantPast)
    }

    @Test(arguments: [(AudioRetentionAge.days14, 14), (.days30, 30), (.days90, 90)])
    func selectedAgeAppliesToExpirationAndPurgeCutoff(age: AudioRetentionAge, days: Int) {
        let policy = AudioRetentionPolicy(age: age)
        let now = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(policy.expiration(from: now) == now.addingTimeInterval(Double(days) * 86_400))
        #expect(policy.cutoff(at: now) == now.addingTimeInterval(-Double(days) * 86_400))
    }
}
