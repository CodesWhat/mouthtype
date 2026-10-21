import AppKit
import SwiftUI
import MouthtypeCore

/// The Style page: a tone for each kind of writing and the apps that count as each kind, plus the cleanup level for everything.
/// Five tabs, Personal messages, Work messages, Email, Other and Cleanup.
enum StyleTab: Hashable, CaseIterable {
    case context(StyleContextID)
    case cleanup

    static let allCases: [StyleTab] = StyleContextID.allCases.map { .context($0) } + [.cleanup]

    var title: String {
        switch self {
        case .context(let id): id.title
        case .cleanup: "Cleanup"
        }
    }
}

struct StylePage: View {
    @Bindable var model: SettingsModel
    var actions = SettingsActions()
    @State var tab: StyleTab

    init(model: SettingsModel, actions: SettingsActions = SettingsActions(), initialTab: StyleTab = .context(.personal)) {
        self.model = model
        self.actions = actions
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            StyleTabBar(selection: $tab)
            switch tab {
            case .context(let id): StyleContextTab(model: model, actions: actions, context: id, openCleanup: { tab = .cleanup })
            case .cleanup: StyleCleanupTab(model: model, actions: actions, open: { tab = .context($0) })
            }
        }
    }
}

// MARK: Tabs

struct StyleTabBar: View {
    @Binding var selection: StyleTab

    var body: some View {
        HStack(spacing: 24) {
            ForEach(StyleTab.allCases, id: \.self) { tab in
                let selected = tab == selection
                Button { selection = tab } label: {
                    Text(tab.title).font(DesignFont.sans(DesignFont.body, .medium))
                        .foregroundStyle(selected ? DesignPalette.ink : DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 2).padding(.top, 2).padding(.bottom, 10)
                        .overlay(alignment: .bottom) { Rectangle().fill(selected ? DesignPalette.ink : Color.clear).frame(height: 2) }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(tab.title).accessibilityAddTraits(selected ? .isSelected : [])
                .accessibilityIdentifier("style-tab-" + Self.slug(tab))
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .bottom) { Rectangle().fill(DesignPalette.hair).frame(height: 1) }
        .onKeyPress(.leftArrow) { step(-1) }
        .onKeyPress(.rightArrow) { step(1) }
        .accessibilityElement(children: .contain).accessibilityLabel("Style tabs")
    }

    static func slug(_ tab: StyleTab) -> String {
        switch tab {
        case .context(let id): id.rawValue
        case .cleanup: "cleanup"
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        guard let index = StyleTab.allCases.firstIndex(of: selection) else { return .ignored }
        let next = min(max(index + offset, 0), StyleTab.allCases.count - 1)
        selection = StyleTab.allCases[next]
        return .handled
    }
}

// MARK: Context tab

private extension StylePreset {
    var blurb: String {
        switch self {
        case .formal: "Sentence case. Keeps your punctuation. Softens swearing."
        case .casual: "Sentence case. No full stop at the end."
        case .veryCasual: "Lowercase starts. No full stop at the end."
        }
    }
}

struct StyleContextTab: View {
    @Bindable var model: SettingsModel
    var actions: SettingsActions
    let context: StyleContextID
    var openCleanup: () -> Void = {}

    private var tone: StylePreset? { context == .other ? model.cleanup.style.preset : model.appStyles.contexts.tone(context) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 8) {
                DesignEyebrow(toneEyebrow)
                HStack(alignment: .top, spacing: 12) {
                    ForEach(StylePreset.allCases, id: \.rawValue) { preset in
                        StyleToneCard(preset: preset, selected: tone == preset,
                                      rendered: StyleSamples.render(StyleSamples.lines(for: context), tone: preset)) {
                            model.setContextTone(context, preset)
                        }
                    }
                }
                if context == .other, tone == nil {
                    Text("A custom tone is active. Choose a preset to replace it.")
                        .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2).padding(.horizontal, 4)
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) { members.frame(minWidth: 280, maxWidth: .infinity); aside.frame(width: 260) }
                VStack(alignment: .leading, spacing: 18) { members; aside }
            }
            if context == .other { StyleOwnRules(model: model) }
        }
    }

    @ViewBuilder private var members: some View {
        if context.hasList {
            StyleMembersCard(model: model, context: context)
        } else {
            VStack(alignment: .leading, spacing: 8) {
                DesignEyebrow("Counts as other")
                DesignCard {
                    DesignRow(title: "Everything not listed under Personal, Work or Email",
                              detail: "Terminals, editors and any app or website with no list of its own. It uses the tone above.") { EmptyView() }
                }
            }
        }
    }

    private var aside: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Cleanup here").font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                    Text(cleanupDetail).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
                DesignPopup(title: "Cleanup for \(context.noun)", selection: Binding(
                    get: { model.appStyles.contexts.level(context) }, set: { model.setContextLevel(context, $0) }), choices: levelChoices)
                    .accessibilityIdentifier("style-cleanup-here")
            }
            .padding(.horizontal, 16).padding(.vertical, 14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            Text(footnote).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }.padding(.top, context.hasList ? 22 : 0)
    }

    private var toneEyebrow: String {
        switch context {
        case .personal: "Tone for personal messages"
        case .work: "Tone for work messages"
        case .email: "Tone for email"
        case .other: "Tone for everything else"
        }
    }

    private var levelChoices: [DesignChoice<CleanupLevel?>] {
        [DesignChoice<CleanupLevel?>("Same as everywhere · \(model.cleanup.level.title)", nil)]
            + CleanupLevel.allCases.map { DesignChoice<CleanupLevel?>($0.title, $0) }
    }

    private var cleanupDetail: String {
        switch context {
        case .personal: "Set on the Cleanup tab for everything. Change it here only if personal messages should differ."
        case .work: "Set on the Cleanup tab for everything. Change it here only if work messages should differ."
        case .email: "Set on the Cleanup tab for everything. Long emails are where Thorough earns its keep, if you want it only here."
        case .other: "Set on the Cleanup tab for everything. Basic here keeps a model from rewriting a command in a terminal."
        }
    }

    private var footnote: String {
        switch context {
        case .email: "Say \"new paragraph\" to break lines. That's a spoken command, so it works at every tone."
        default: "Anything not listed under Personal, Work or Email counts as Other. A website wins over the browser it's in."
        }
    }
}

// MARK: Tone card

struct StyleToneCard: View {
    let preset: StylePreset
    let selected: Bool
    let rendered: [[StyleSampleSegment]]
    let action: () -> Void

    static func attributed(_ segments: [StyleSampleSegment]) -> AttributedString {
        var out = AttributedString()
        for segment in segments {
            var piece = AttributedString(segment.text)
            if segment.added {
                piece.backgroundColor = DesignPalette.sel
                piece.foregroundColor = DesignPalette.ink
            }
            out += piece
        }
        return out
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Text(preset.title).font(DesignFont.serif(DesignFont.display)).foregroundStyle(DesignPalette.ink)
                    .fixedSize(horizontal: false, vertical: true)
                Text(preset.blurb).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(rendered.indices, id: \.self) { index in
                        Text(Self.attributed(rendered[index])).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2).lineSpacing(2)
                .padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.bg))
            }
            .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 12)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? DesignPalette.ink : DesignPalette.hair2, lineWidth: selected ? 1.5 : 1))
            .overlay(alignment: .topTrailing) { if selected { StyleCheck().padding(12) } }
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title) tone")
        .accessibilityValue(StyleSamples.plainText(rendered))
        .accessibilityHint(preset.blurb)
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("style-tone-" + preset.rawValue)
    }
}

struct StyleCheck: View {
    var body: some View {
        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DesignPalette.surface)
            .frame(width: 18, height: 18).background(Circle().fill(DesignPalette.ink)).accessibilityHidden(true)
    }
}

// MARK: Members

struct StyleMembersCard: View {
    @Bindable var model: SettingsModel
    let context: StyleContextID
    @State private var addingSite = false
    @State private var domain = ""

    @State private var installRevision = 0

    private var rows: [StyleRows.Row] { _ = installRevision; return StyleRows.rows(for: context, in: model.appStyles) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow("Counts as \(context.noun)")
            DesignCard {
                ForEach(rows) { row in memberRow(row) }
                if addingSite { siteField }
                addRow
                if let error = model.appStylesError { errorRow(error) }
            }
        }
        .onAppear { AppIconResolver.invalidateMisses(); installRevision += 1 }
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didLaunchApplicationNotification)) { _ in
            AppIconResolver.invalidateMisses(); installRevision += 1
        }
    }

    private func memberRow(_ row: StyleRows.Row) -> some View {
        let member = row.member
        let key = member.keys.first ?? member.name
        let isApp = member.kind == .app
        let contextTone = model.appStyles.contexts.tone(context)
        return HStack(spacing: 12) {
            StyleMemberIcon(member: member)
            Text(member.name).font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Text(row.isBuiltIn ? "BUILT IN" : "ADDED BY YOU").font(DesignFont.mono(10)).tracking(0.9).foregroundStyle(DesignPalette.ink3)
                .fixedSize()
            DesignPopup(title: "Tone for \(member.name)", selection: Binding(
                get: { row.ruleStyle.map { $0.preset?.rawValue ?? "custom" } ?? "same" },
                set: { value in
                    let tone = StylePreset(rawValue: value)
                    if isApp { model.setAppStyle(bundleIDs: row.targets, appName: member.name, tone: tone) }
                    else { model.setWebsiteStyle(domain: key, tone: tone) }
                }), choices: toneChoices(row, contextTone: contextTone))
                .accessibilityIdentifier("style-member-tone")
            DesignPopup(title: "Cleanup for \(member.name)", selection: Binding(
                get: { row.ruleLevel },
                set: { level in
                    if isApp { model.setAppCleanupLevel(bundleIDs: row.targets, appName: member.name, level: level) }
                    else { model.setWebsiteCleanupLevel(domain: key, level: level) }
                }), choices: levelChoices)
                .accessibilityIdentifier("style-member-cleanup")
            Button {
                if row.ownRule {
                    if isApp { model.removeAppStyles(bundleIDs: row.targets) } else { model.removeWebsiteStyle(domain: key) }
                } else {
                    model.removeContextMember(member, bundleIDs: isApp ? row.targets : nil, from: context)
                }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).accessibilityLabel("Remove \(member.name) from \(context.noun)")
        }
        .padding(.leading, 14).padding(.trailing, 10).padding(.vertical, 6).frame(minHeight: 40)
        .disabled(model.appStylesError != nil)
    }

    private func toneChoices(_ row: StyleRows.Row, contextTone: StylePreset?) -> [DesignChoice<String>] {
        let name = contextTone?.title ?? context.title
        var choices = [DesignChoice("Same as \(context.noun) · \(name)", "same")] + StylePreset.allCases.map { DesignChoice($0.title, $0.rawValue) }
        if let style = row.ruleStyle, style.preset == nil { choices.append(DesignChoice("Custom", "custom")) }
        return choices
    }

    private var levelChoices: [DesignChoice<CleanupLevel?>] {
        let name = model.appStyles.contexts.level(context).map(\.title) ?? model.cleanup.level.title
        return [DesignChoice<CleanupLevel?>("Same as \(context.noun) · \(name)", nil)]
            + CleanupLevel.allCases.map { DesignChoice<CleanupLevel?>($0.title, $0) }
    }

    private var addRow: some View {
        Menu {
            Button("Choose an application…") { model.chooseApplication(for: context) }
            Button("Add a website…") { addingSite = true }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignPalette.ink)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.sel))
                Text("Add an app or website").font(DesignFont.sans(DesignFont.body, .medium)).foregroundStyle(DesignPalette.ink)
            }
            .padding(.horizontal, 6).frame(minHeight: 32).contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .padding(.horizontal, 8).padding(.vertical, 5).frame(maxWidth: .infinity, alignment: .leading)
        .disabled(model.appStylesError != nil)
        .accessibilityLabel("Add an app or website to \(context.noun)").accessibilityIdentifier("style-add-member")
    }

    private var siteField: some View {
        HStack(spacing: 8) {
            TextField("Domain, e.g. slack.com", text: $domain).textFieldStyle(.roundedBorder).accessibilityLabel("Website domain")
                .accessibilityIdentifier("style-website-domain").onSubmit(commit)
            Button("Add", action: commit).buttonStyle(.designPrimary)
                .disabled(domain.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("Cancel") { addingSite = false; domain = "" }.buttonStyle(.designSecondary)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }

    private func commit() {
        model.addContextSite(context, domain: domain)
        if model.appStylesError == nil { domain = ""; addingSite = false }
    }

    private func errorRow(_ error: String) -> some View {
        HStack {
            Text(error).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.danger).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Reload") { model.refresh() }.buttonStyle(.designSecondary)
        }.padding(.horizontal, 14).padding(.vertical, 8)
    }
}

/// Looks up an app's real icon by bundle ID, caching hits and misses. Nil means not installed.
enum AppIconResolver {
    nonisolated(unsafe) private static let cache = NSCache<NSString, NSImage>()
    nonisolated(unsafe) private static let misses = NSCache<NSString, NSNumber>()

    static func cachedIcon(bundleIDs: [String]) -> NSImage? {
        for id in bundleIDs { if let icon = cache.object(forKey: id as NSString) { return icon } }
        return nil
    }

    static func invalidateMisses() { misses.removeAllObjects() }

    static func icon(bundleIDs: [String]) -> NSImage? {
        for id in bundleIDs {
            let key = id as NSString
            if let icon = cache.object(forKey: key) { return icon }
            if misses.object(forKey: key) != nil { continue }
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) {
                let icon = NSWorkspace.shared.icon(forFile: url.path)
                cache.setObject(icon, forKey: key)
                return icon
            }
            misses.setObject(true, forKey: key)
        }
        return nil
    }
}

/// The app's real icon, a letter tile in the app's colour when it isn't installed, or a globe for a website.
struct StyleMemberIcon: View {
    let member: StyleMember
    @State private var loaded: NSImage?

    private static let brand: [String: UInt32] = [
        "Messages": 0x34C759, "WhatsApp": 0x25D366, "Telegram": 0x2AABEE, "Discord": 0x5865F2, "Signal": 0x3A76F0,
        "Slack": 0x4A154B, "Microsoft Teams": 0x5059C9, "Mail": 0x1E6FD9, "Outlook": 0x0F6CBD,
    ]

    var body: some View {
        Group {
            if member.kind == .site {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(DesignPalette.ink2)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.sel))
            } else if let icon = loaded ?? AppIconResolver.cachedIcon(bundleIDs: member.keys) {
                Image(nsImage: icon).resizable().frame(width: 24, height: 24)
            } else {
                Text(String(member.name.prefix(1)).uppercased()).font(DesignFont.sans(11, .semibold)).foregroundStyle(Color.white)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Self.brand[member.name].map { Color(hex: $0) } ?? DesignPalette.ink3))
            }
        }
        .accessibilityHidden(true)
        .task(id: member.keys) {
            guard member.kind == .app, loaded == nil else { return }
            let ids = member.keys
            loaded = await Task.detached(priority: .userInitiated) { AppIconResolver.icon(bundleIDs: ids) }.value
        }
    }
}

private extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }
}

// MARK: Own rules

/// Rules made before contexts existed that no context's tone matches. They keep winning over the contexts, and stay editable here.
struct StyleOwnRules: View {
    @Bindable var model: SettingsModel

    var body: some View {
        let rules = StyleRows.ownRules(in: model.appStyles)
        if !rules.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                DesignEyebrow("Your own rules")
                DesignCard {
                    ForEach(rules) { rule in row(rule) }
                }
                Text("Rules you set for one app or website win over its list. A website rule wins over the browser it's in.")
                    .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
            }
        }
    }

    private func row(_ rule: StyleRows.OwnRule) -> some View {
        let member = rule.member
        let isApp = member.kind == .app
        let key = member.keys.first ?? member.name
        return DesignRow(title: member.name, detail: isApp ? key : nil) {
            DesignPopup(title: "Tone for \(member.name)", selection: Binding(
                get: { rule.style.map { $0.preset?.rawValue ?? "custom" } ?? "default" },
                set: { value in
                    let tone = StylePreset(rawValue: value)
                    if isApp { model.setAppStyle(bundleID: key, appName: member.name, tone: tone) } else { model.setWebsiteStyle(domain: key, tone: tone) }
                }), choices: toneChoices(rule))
            DesignPopup(title: "Cleanup for \(member.name)", selection: Binding(
                get: { rule.level },
                set: { level in
                    if isApp { model.setAppCleanupLevel(bundleID: key, appName: member.name, level: level) }
                    else { model.setWebsiteCleanupLevel(domain: key, level: level) }
                }), choices: levelChoices)
            Button {
                if isApp { model.removeAppStyle(bundleID: key) } else { model.removeWebsiteStyle(domain: key) }
            } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(DesignPalette.ink3)
                    .frame(width: 28, height: 28).contentShape(RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain).accessibilityLabel("Remove rule for \(member.name)")
        }.disabled(model.appStylesError != nil)
    }

    private func toneChoices(_ rule: StyleRows.OwnRule) -> [DesignChoice<String>] {
        var choices = [DesignChoice("Use default tone", "default")] + StylePreset.allCases.map { DesignChoice($0.title, $0.rawValue) }
        if let style = rule.style, style.preset == nil { choices.append(DesignChoice("Custom", "custom")) }
        return choices
    }

    private var levelChoices: [DesignChoice<CleanupLevel?>] {
        [DesignChoice<CleanupLevel?>("Cleanup: use default", nil)] + CleanupLevel.allCases.map { DesignChoice<CleanupLevel?>("Cleanup: \($0.title)", $0) }
    }
}
