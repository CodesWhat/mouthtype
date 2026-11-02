import AppKit

/// Where people can chip in. Mouthtype is free and open source; these two links live in the menu bar menu and the About panel, and
/// nowhere else in the app. Nothing here prompts, nags or runs at launch.
enum SupportLinks {
    struct Destination: Equatable {
        let title: String
        let url: URL
    }

    static let gitHubSponsors = Destination(title: "GitHub Sponsors", url: URL(string: "https://github.com/sponsors/CodesWhat")!)
    static let donate = Destination(title: "Donate", url: URL(string: "https://codeswhat.com/support")!)
    static let all = [gitHubSponsors, donate]

    static let menuTitle = "Support Mouthtype"

    /// The About panel's credits line.
    static func credits() -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: paragraph,
        ]
        let text = NSMutableAttributedString(
            string: "Mouthtype is free and open source. If it saves you time, you can support it on ", attributes: base)
        text.append(link(gitHubSponsors, text: gitHubSponsors.title, base: base))
        text.append(NSAttributedString(string: " or ", attributes: base))
        text.append(link(donate, text: "donate directly", base: base))
        text.append(NSAttributedString(string: ".", attributes: base))
        return text
    }

    private static func link(_ destination: Destination, text: String, base: [NSAttributedString.Key: Any]) -> NSAttributedString {
        var attributes = base
        attributes[.link] = destination.url
        return NSAttributedString(string: text, attributes: attributes)
    }
}
