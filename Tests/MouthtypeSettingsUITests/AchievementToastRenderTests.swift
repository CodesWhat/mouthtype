import AppKit
import SwiftUI
import Testing
import MouthtypeCore
@testable import MouthtypeMac

/// Offscreen renders of the trophy toast in the corner of a window, Classic and Hi-Fi, light and dark. Set
/// `MOUTHTYPE_SETTINGS_PREVIEWS` to a directory to keep the PNGs.
@MainActor @Suite(.serialized) struct AchievementToastRenderTests {
    private func isolatedDefaults() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-toast-render-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func center(ids: [String], defaults: UserDefaults) -> AchievementToastCenter {
        let center = AchievementToastCenter(store: AchievementStore(defaults: defaults), autoSchedule: false)
        center.announce = { _ in }
        center.playCue = {}
        center.windowIsKey = true
        center.ingest(
            ids.map { id in
                let definition = AchievementCatalog.definition(id: id)!
                return AchievementShelfEntry(
                    id: id, group: definition.group, tier: definition.tier, name: definition.name, copy: definition.copy,
                    state: .earned(day: "2026-11-02"), isApproximate: false, isNew: true)
            })
        return center
    }

    /// A window's worth of Stats page ghosted behind the toast.
    private func scene(_ center: AchievementToastCenter, skin: PillSkinKind) -> some View {
        ZStack(alignment: .topLeading) {
            DesignPalette.bg
            VStack(alignment: .leading, spacing: 9) {
                Text("Your numbers.").font(DesignFont.serif(28)).foregroundStyle(DesignPalette.ink)
                RoundedRectangle(cornerRadius: 6).fill(DesignPalette.hair2).frame(width: 300, height: 12)
                RoundedRectangle(cornerRadius: 6).fill(DesignPalette.hair2).frame(width: 190, height: 12)
            }.padding(24)
            AchievementToastHost(center: center, skin: skin, readout: .default)
        }
        .frame(width: 640, height: 300)
    }

    private func render(skin: PillSkinKind, name: String, ids: [String]) throws {
        FontRegistry.registerBundledFonts()
        for dark in [false, true] {
            let (defaults, cleanup) = isolatedDefaults()
            defer { cleanup() }
            let center = center(ids: ids, defaults: defaults)
            #expect(center.current != nil)
            let bitmap = try SettingsRender.render(scene(center, skin: skin), dark: dark, size: NSSize(width: 640, height: 300))
            #expect(bitmap.pixelsWide >= 640)
            try SettingsRender.save(bitmap, name: "\(name)-\(dark ? "dark" : "light")")
        }
    }

    @Test func classicToastRendersLightAndDark() throws {
        try render(skin: .classic, name: "toast-classic", ids: ["four_figures"])
    }

    @Test func hiFiToastRendersLightAndDark() throws {
        try render(skin: .hifi, name: "toast-hifi", ids: ["four_figures"])
    }

    @Test func collapsedToastRendersInBothSkins() throws {
        try render(skin: .classic, name: "toast-collapsed-classic", ids: ["first_words", "hands_free", "four_figures"])
        try render(skin: .hifi, name: "toast-collapsed-hifi", ids: ["first_words", "hands_free", "four_figures"])
    }
}
