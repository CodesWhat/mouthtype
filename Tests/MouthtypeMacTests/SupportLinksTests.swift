import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite struct SupportLinksTests {
    @Test func destinationsAreExact() {
        #expect(SupportLinks.gitHubSponsors.url.absoluteString == "https://github.com/sponsors/CodesWhat")
        #expect(SupportLinks.donate.url.absoluteString == "https://codeswhat.com/support")
        #expect(SupportLinks.all.map(\.title) == ["GitHub Sponsors", "Donate"])
    }

    @Test func menuHasASupportSubmenuNextToAboutAndNoIcons() throws {
        let daily = DailyMenu()
        let titles = daily.menu.items.map(\.title)
        let about = try #require(titles.firstIndex(of: "About Mouthtype"))
        #expect(titles[about + 1] == "Support Mouthtype")
        let support = try #require(daily.menu.items.first { $0.title == "Support Mouthtype" })
        #expect(support.image == nil)
        let submenu = try #require(support.submenu)
        #expect(submenu.items.map(\.title) == ["GitHub Sponsors", "Donate"])
        #expect(submenu.items.compactMap { $0.representedObject as? URL } == SupportLinks.all.map(\.url))
        #expect(submenu.items.allSatisfy { $0.image == nil && $0.action != nil && $0.target != nil })
    }

    @Test func creditsLinkBothDestinations() {
        let credits = SupportLinks.credits()
        #expect(
            credits.string
                == "Mouthtype is free and open source. If it saves you time, you can support it on GitHub Sponsors or donate directly.")
        var links: [URL] = []
        credits.enumerateAttribute(.link, in: NSRange(location: 0, length: credits.length)) { value, _, _ in
            if let url = value as? URL { links.append(url) }
        }
        #expect(links == SupportLinks.all.map(\.url))
    }

    /// Writes light and dark renders of the About panel credits when `SUPPORT_RENDER_DIR` is set. A no-op otherwise.
    @Test func rendersCreditsInLightAndDark() throws {
        guard let directory = ProcessInfo.processInfo.environment["SUPPORT_RENDER_DIR"] else { return }
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        for (name, appearanceName) in [("light", NSAppearance.Name.aqua), ("dark", NSAppearance.Name.darkAqua)] {
            let appearance = try #require(NSAppearance(named: appearanceName))
            let size = NSSize(width: 340, height: 140)
            let root = NSView(frame: NSRect(origin: .zero, size: size))
            let title = NSTextField(labelWithString: "Mouthtype")
            title.font = .boldSystemFont(ofSize: 15)
            title.alignment = .center
            title.frame = NSRect(x: 0, y: 100, width: size.width, height: 22)
            let credits = NSTextView(frame: NSRect(x: 20, y: 20, width: size.width - 40, height: 64))
            credits.drawsBackground = false
            credits.isEditable = false
            credits.textStorage?.setAttributedString(SupportLinks.credits())
            root.addSubview(title)
            root.addSubview(credits)
            let window = NSWindow(contentRect: root.frame, styleMask: .titled, backing: .buffered, defer: true)
            window.appearance = appearance
            window.contentView = root
            root.layoutSubtreeIfNeeded()
            root.appearance = appearance
            NSApplication.shared.appearance = appearance
            defer { NSApplication.shared.appearance = nil }
            root.wantsLayer = true
            appearance.performAsCurrentDrawingAppearance { root.layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor }
            let bitmap = try #require(root.bitmapImageRepForCachingDisplay(in: root.bounds))
            appearance.performAsCurrentDrawingAppearance { root.cacheDisplay(in: root.bounds, to: bitmap) }
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: directory).appendingPathComponent("about-credits-\(name).png"))
        }
    }
}
