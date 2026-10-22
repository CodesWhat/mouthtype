import AppKit
import MouthtypeCore

/// The Style page's edits. Contexts live inside `AppCleanupStyles` so dictation resolves them with the same call it always made;
/// every change goes through `updateAppStyles`, which reloads, applies, saves and surfaces a storage error.
extension SettingsModel {
    func setContextTone(_ context: StyleContextID, _ tone: StylePreset) {
        if context == .other { setTone(tone); return }
        updateAppStyles { $0.contexts.setTone(context, tone) }
    }

    func setContextLevel(_ context: StyleContextID, _ level: CleanupLevel?) {
        updateAppStyles { $0.contexts.setLevel(context, level) }
    }

    /// An explicit rule you made on the same app earlier keeps beating a list, so one that set only a tone is replaced by the list.
    /// A rule that also sets a cleanup level stays: it is still your override.
    func addContextApp(_ context: StyleContextID, bundleID: String, appName: String) {
        updateAppStyles { styles in
            if let rule = styles.entries.first(where: { $0.bundleID == bundleID }), rule.level == nil { styles.remove(bundleID: bundleID) }
            styles.contexts.addApp(context, bundleID: bundleID, appName: appName)
        }
    }

    func addContextSite(_ context: StyleContextID, domain: String) {
        updateAppStyles { styles in
            guard let normal = AppCleanupStyles.normalizedDomain(domain) else { throw AppCleanupStyles.ValidationError.invalidDomain }
            if let rule = styles.websiteRule(domain: normal), rule.level == nil { styles.removeWebsite(domain: normal) }
            styles.contexts.addSite(context, domain: normal)
        }
    }

    /// Removing a row also drops your own rule on the same app or site, which would otherwise keep it listed. `bundleIDs` limits an
    /// app removal to one split row's identifiers, so the sibling row keeps its membership and its overrides.
    func removeContextMember(_ member: StyleMember, bundleIDs: [String]? = nil, from context: StyleContextID) {
        let keys = member.kind == .app ? (bundleIDs ?? member.keys) : member.keys
        updateAppStyles { styles in
            styles.contexts.remove(member, keys: keys, from: context)
            if member.kind == .app { keys.forEach { styles.remove(bundleID: $0) } } else { keys.forEach { styles.removeWebsite(domain: $0) } }
        }
    }

    func chooseApplication(for context: StyleContextID) {
        let panel = NSOpenPanel()
        panel.title = "Choose an application"
        panel.prompt = "Add to \(context.title)"
        panel.allowedContentTypes = [.applicationBundle]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url else { return }
            self?.addApplication(at: url, to: context)
        }
    }

    func addApplication(at url: URL, to context: StyleContextID) {
        guard url.pathExtension.lowercased() == "app", let bundle = Bundle(url: url), let bundleID = bundle.bundleIdentifier else {
            updateAppStyles { _ in throw StyleEditError.noBundleID }
            return
        }
        let name =
            bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? bundle.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? url.deletingPathExtension().lastPathComponent
        addContextApp(context, bundleID: bundleID, appName: name)
    }
}

private enum StyleEditError: LocalizedError {
    case noBundleID
    var errorDescription: String? { "That application has no readable bundle identifier." }
}
