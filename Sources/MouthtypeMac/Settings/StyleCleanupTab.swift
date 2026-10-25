import SwiftUI
import MouthtypeCore

/// The Cleanup tab: the level for every take in every app, each with the same messy take as it comes out, and the contexts that
/// override it.
struct StyleCleanupTab: View {
    @Bindable var model: SettingsModel
    var actions: SettingsActions
    var open: (StyleContextID) -> Void = { _ in }

    private let basic = StyleSamples.basicOutput()

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    DesignEyebrow("Cleanup · every take, in every app")
                    Spacer(minLength: 8)
                    Text("RUNS ON THIS MAC").font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).foregroundStyle(DesignPalette.ink3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack(alignment: .top, spacing: 12) {
                    ForEach(CleanupLevel.allCases, id: \.rawValue) { level in card(level) }
                }
            }
            differences
            instructions
            if model.showsFastLanguageNote {
                Text(DictationLanguageSetting.fastEnglishOnlyNote)
                    .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                    .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
                    .accessibilityIdentifier("style-fast-language-note")
            }
            Text("Fast and Thorough run on this Mac. Takes use Basic until a model is ready.\(modelNote)")
                .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    // MARK: Level cards

    private func card(_ level: CleanupLevel) -> some View {
        let selected = model.cleanup.level == level
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                model.setLevel(level)
            } label: {
                VStack(alignment: .leading, spacing: 8) {
                    Text(level.title).font(DesignFont.serif(20)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                    Text(blurb(level)).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(sample(level)).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, 11).padding(.vertical, 9).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.bg))
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(level.title) cleanup").accessibilityValue(sample(level))
            .accessibilityAddTraits(selected ? .isSelected : [])
            .accessibilityIdentifier("style-level-" + level.rawValue)
            status(level, selected: selected)
        }
        .padding(.top, 14).padding(.horizontal, 14).padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? DesignPalette.ink : DesignPalette.hair2, lineWidth: selected ? 1.5 : 1))
        .overlay(alignment: .topTrailing) { if selected { StyleCheck().padding(12) } }
    }

    private func blurb(_ level: CleanupLevel) -> String {
        switch level {
        case .off: "Exactly what you said, mistakes and all."
        case .basic: "Fillers, numbers and tidy-ups. Nothing reworded."
        case .light: "Self-corrections and repeats fixed by a small local model."
        case .medium: "A bigger local model for long, messy takes. Slower."
        }
    }

    private func sample(_ level: CleanupLevel) -> String {
        switch level {
        case .off: StyleSamples.messyEngine
        case .basic: basic
        case .light: StyleSamples.fastExample
        case .medium: StyleSamples.thoroughExample
        }
    }

    @ViewBuilder private func status(_ level: CleanupLevel, selected: Bool) -> some View {
        if !level.needsModel {
            statusText("NO MODEL · INSTANT")
        } else if selected, let cleaner = actions.cleaner {
            switch cleaner.state {
            case .ready:
                HStack(spacing: 6) {
                    Circle().fill(DesignPalette.success).frame(width: 6, height: 6).accessibilityHidden(true); statusText("READY")
                }
            case .absent, .failed:
                HStack(spacing: 8) {
                    statusText(cleaner.state == .absent ? "NOT DOWNLOADED" : "FAILED")
                    Button("DOWNLOAD…") {
                        let target = cleaner.downloadTarget
                        if CleanupModelDownloadConfirmation.askToDownload(name: target.modelName, sizeMB: target.downloadSizeMB) { target.startDownload() }
                    }.buttonStyle(.plain).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).foregroundStyle(DesignPalette.ink)
                        .underline().accessibilityLabel("Download the cleanup model")
                }
            case .downloading(let fraction):
                HStack(spacing: 8) {
                    statusText("DOWNLOADING \(Int(fraction * 100))%")
                    Button("CANCEL") { cleaner.cancelDownload() }.buttonStyle(.plain).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8)
                        .foregroundStyle(DesignPalette.ink).underline().accessibilityLabel("Cancel the model download")
                }
            case .loading: statusText("LOADING")
            case .unloaded: statusText("DOWNLOADED · LOADS WHEN NEEDED")
            }
        } else {
            statusText("LOCAL MODEL · EXAMPLE")
        }
    }

    private func statusText(_ text: String) -> some View {
        Text(text).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).foregroundStyle(DesignPalette.ink3).fixedSize(horizontal: false, vertical: true)
    }

    /// The model's full state line, including the failure message a short status can't carry.
    private var modelNote: String {
        guard let cleaner = actions.cleaner else { return "" }
        let name = cleaner.modelName
        switch cleaner.state {
        case .absent: return " \(name) is not downloaded."
        case .downloading(let fraction): return " \(name) is downloading: \(Int(fraction * 100))%."
        case .loading: return " \(name) is loading."
        case .unloaded: return " \(name) is downloaded and loads when needed."
        case .ready: return " \(name) is ready."
        case .failed(let message): return " \(name): \(message)"
        }
    }

    // MARK: Instructions

    private var instructions: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow("Instructions · Thorough only")
            DesignCard {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Tell Thorough how your text should read. Apps and websites can have their own.")
                        .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                    StyleInstructionsEditor(
                        saved: CleanupInstructions.normalize(model.cleanup.instructions), placeholder: StyleContextID.other.instructionsExample,
                        label: "Instructions for every app", identifier: "style-instructions-global"
                    ) { model.setInstructions($0 ?? "") }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
        }
    }

    // MARK: Differences

    private var differences: some View {
        let styles = model.appStyles
        let overrides = styles.contexts.overridingLevels
        let following = StyleContextID.allCases.filter { id in !overrides.contains { $0.context == id } }
        let ownLevels = styles.entries.filter { $0.level != nil }.count + styles.websites.filter { $0.level != nil }.count
        return VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow("Where it's different")
            DesignCard {
                ForEach(overrides, id: \.context) { override in
                    DesignRow(title: override.context.title, detail: detail(override.context)) {
                        Text(override.level.title.uppercased()).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink)
                        Button("Change on its tab") { open(override.context) }.buttonStyle(.plain)
                            .font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink).underline()
                    }
                }
                if ownLevels > 0 {
                    DesignRow(
                        title: "\(ownLevels) of your own app or website \(ownLevels == 1 ? "rule sets" : "rules set") a cleanup level",
                        detail: "They win over the lists. Look under the matching tab."
                    ) { EmptyView() }
                }
                DesignRow(title: followText(following, level: model.cleanup.level)) {
                    Text("\(following.count) OF \(StyleContextID.allCases.count) FOLLOW").font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8)
                        .foregroundStyle(DesignPalette.ink3)
                }
            }
        }
    }

    private func detail(_ id: StyleContextID) -> String {
        id == .other ? "Terminals, editors and everything unlisted." : "Apps and websites listed under \(id.title)."
    }

    private func followText(_ ids: [StyleContextID], level: CleanupLevel) -> String {
        if ids.isEmpty { return "Every context sets its own level." }
        let names = ids.map(\.title)
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names[names.count - 1] : names[0]
        return "\(list) use \(level.title), the level above."
    }
}
