import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// The Hi-Fi toast draws every trophy's words in the pixel faces, or says it cannot so the Classic toast takes over.
@MainActor @Suite struct HiFiAchievementToastTests {
    private func toast(_ definition: AchievementDefinition) -> AchievementToast {
        var scheduler = AchievementToastScheduler()
        scheduler.enqueue([AchievementToastEarn(id: definition.id, name: definition.name, copy: definition.copy, tier: definition.tier)])
        return scheduler.poll(AchievementToastContext(now: Date(), windowIsKey: true))!
    }

    @Test func everyCatalogTrophyComposesOrFallsBackWholeNeverCutShort() throws {
        let assets = try #require(HiFiCardAssets.shared)
        var composed = 0
        for definition in AchievementCatalog.all {
            let toast = toast(definition)
            if let face = HiFiAchievementToast.compose(toast: toast, assets: assets, readout: .default, fraction: 1) {
                composed += 1
                #expect(face.image.width == face.frames.width && face.image.height == face.frames.height)
            }
        }
        // The pixel faces cover the whole catalog today; a new trophy that they cannot draw would fall back to Classic.
        #expect(composed == AchievementCatalog.all.count)
    }

    @Test func collapsedAndBackfillToastsCompose() throws {
        let assets = try #require(HiFiCardAssets.shared)
        var scheduler = AchievementToastScheduler(backfillCount: 12)
        let first = scheduler.poll(AchievementToastContext(now: Date(), windowIsKey: true, statsOpen: true))
        let backfill = try #require(first)
        #expect(HiFiAchievementToast.compose(toast: backfill, assets: assets, readout: .default, fraction: 0.5) != nil)
        scheduler.enqueue(AchievementCatalog.all.prefix(4).map { AchievementToastEarn(id: $0.id, name: $0.name, copy: $0.copy, tier: $0.tier) })
        let later = Date().addingTimeInterval(700)
        let second = scheduler.poll(AchievementToastContext(now: later, windowIsKey: true))
        let collapsed = try #require(second)
        #expect(HiFiAchievementToast.compose(toast: collapsed, assets: assets, readout: .default, fraction: 0.5) != nil)
    }
}
