import Foundation

/// A page the `open` verb can show. `home` and `settings` are destinations; the rest are Settings pages by name.
enum AutomationPage: String, CaseIterable, Equatable {
    case home, settings, general, writing, appearance, diagnostics

    /// The sidebar page this opens in the Mouthtype window. `settings` has no page of its own: it shows the window where it is.
    var settingsPage: SettingsPage? {
        self == .settings ? nil : SettingsPage(rawValue: rawValue)
    }
}

/// The whole `mouthtype://` operation set. Each verb is exactly one case, and each case reaches exactly one action.
enum AutomationCommand: Equatable {
    case start, stop, toggle, cancel, copyLast, pasteLast
    case open(AutomationPage)

    /// The verbs as they appear in the URL host, in documentation order.
    static let verbs = ["start", "stop", "toggle", "cancel", "copy-last", "paste-last", "open"]

    /// The verb this command was parsed from.
    var verb: String {
        switch self {
        case .start: "start"
        case .stop: "stop"
        case .toggle: "toggle"
        case .cancel: "cancel"
        case .copyLast: "copy-last"
        case .pasteLast: "paste-last"
        case .open: "open"
        }
    }

    /// Operations that only show UI. Everything else records, inserts or copies, so it needs the opt-in.
    var needsOptIn: Bool {
        if case .open = self { return false }
        return true
    }
}

enum AutomationParseError: Error, Equatable {
    case wrongScheme
    case unknownVerb(String)
    case unknownPage(String)
    case unexpectedPath
}

enum AutomationURL {
    static let scheme = "mouthtype"

    /// `mouthtype://<verb>` or `mouthtype://open?page=<page>`. Strict on purpose: anything else is rejected, not guessed at.
    static func parse(_ url: URL) -> Result<AutomationCommand, AutomationParseError> {
        guard url.scheme?.lowercased() == scheme else { return .failure(.wrongScheme) }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return .failure(.wrongScheme) }
        guard components.path.isEmpty || components.path == "/" else { return .failure(.unexpectedPath) }
        let verb = (components.host ?? "").lowercased()
        switch verb {
        case "start": return .success(.start)
        case "stop": return .success(.stop)
        case "toggle": return .success(.toggle)
        case "cancel": return .success(.cancel)
        case "copy-last": return .success(.copyLast)
        case "paste-last": return .success(.pasteLast)
        case "open":
            let name = components.queryItems?.first { $0.name == "page" }?.value?.lowercased() ?? AutomationPage.settings.rawValue
            guard let page = AutomationPage(rawValue: name) else { return .failure(.unknownPage(name)) }
            return .success(.open(page))
        default:
            return .failure(.unknownVerb(verb))
        }
    }
}
