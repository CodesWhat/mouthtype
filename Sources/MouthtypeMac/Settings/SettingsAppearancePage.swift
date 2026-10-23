import AppKit
import SwiftUI
import MouthtypeCore

extension PillSize {
    /// The size the preview draws: Automatic previews as Standard, because the preview cannot know which screen the pill lands on.
    var previewTitle: String { self == .large ? "Large" : "Standard" }
}

extension PillSkinKind {
    /// The tiles the picker shows. Glass is Classic on the system material, so it is a switch on Classic, not a tile.
    static let pickerKinds: [PillSkinKind] = [.classic, .matrix, .minimal, .hifi]

    /// The tile a stored skin belongs to; a saved `glass` loads as Classic with Glass on.
    var pickerKind: PillSkinKind { self == .glass ? .classic : self }

    /// Classic and Glass share one set of settings, and Glass is the one with its own switch.
    var hasGlassSwitch: Bool { self == .classic || self == .glass }

    /// Whether the delivery cards and pill messages draw with the user's text font. Hi-Fi keeps its own bitmap type, so the
    /// font rows are hidden for it. Matrix draws its pill messages in the text font, and Minimal's pill uses the system font but
    /// its delivery cards still use the text font, so both keep the rows.
    var usesTextFont: Bool { self != .hifi }

    /// Hi-Fi is the only style with a readout colour.
    var hasReadoutColour: Bool { self == .hifi }

    /// What the Text font row says it applies to.
    var textFontDetail: String {
        self == .minimal ? "Used by the delivery cards." : "Used by the pill\u{2019}s messages and the delivery cards."
    }
}

extension SettingsView {
    @ViewBuilder var appearance: some View {
        appearancePreview
        AppearanceStylePicker(selection: model.skin, readout: model.readoutColour, wallpaper: model.previewWallpaper) { kind in
            // Choosing Classic while Glass is on keeps Glass: that is the same tile.
            if kind == .classic, model.skin == .glass { return }
            model.setSkin(kind)
        }
        DesignCard {
            if model.skin.hasGlassSwitch {
                DesignRow(title: "Glass", detail: "Uses the system glass material. Solid when Reduce Transparency is on.") {
                    Toggle("Glass", isOn: Binding(get: { model.skin == .glass }, set: { model.setSkin($0 ? .glass : .classic) }))
                        .labelsHidden().toggleStyle(.designSwitch).accessibilityIdentifier("settings-pill-glass")
                }
            }
            DesignRow(title: "Pill size", detail: "Automatic picks Large on wide screens.") {
                DesignSegmented(
                    title: "Pill size", selection: Binding(get: { model.pillSize }, set: { model.setPillSize($0) }),
                    choices: PillSize.allCases.map { DesignChoice($0.title, $0) }
                )
                .accessibilityIdentifier("settings-pill-size")
            }
            if model.skin.hasReadoutColour {
                DesignRow(title: "Readout colour", detail: "The meter, timer and message text on the chassis.") {
                    DesignSegmented(
                        title: "Readout colour", selection: Binding(get: { model.readoutColour }, set: { model.setReadoutColour($0) }),
                        choices: PillReadoutColour.allCases.map {
                            DesignChoice($0.title, $0, dot: Color(cgColor: PillLayout.color(hex: $0.swatchHex)))
                        }
                    )
                    .accessibilityIdentifier("settings-readout-colour")
                }
            }
            if model.skin.usesTextFont {
                textFontRow
                FontOverridesSection(model: model).rows
            }
        }
        if !model.skin.usesTextFont {
            Text("Hi-Fi uses its own bitmap type, so font settings are hidden.")
                .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        } else if model.fontOverrides.enabled {
            Text("Turning overrides off keeps your choices.")
                .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 4)
        }
    }

    private var textFontRow: some View {
        let standard = TextFontChoice.standard.map { DesignChoice($0.title, $0.title) }
        var choices = standard
        if case .custom = model.font { choices.append(DesignChoice(model.font.title, model.font.title)) }
        return DesignRow(title: model.fontOverrides.enabled ? "Base text font" : "Text font", detail: model.skin.textFontDetail) {
            DesignPopup(
                title: "Text font",
                selection: Binding(
                    get: { model.font.title },
                    set: { name in
                        if let font = TextFontChoice.standard.first(where: { $0.title == name }) { model.setFont(font) }
                    }), choices: choices
            ).accessibilityIdentifier("settings-text-font")
            Button("Choose Font…", action: actions.chooseFont).buttonStyle(.designSecondary)
                .accessibilityLabel("Choose a font").accessibilityIdentifier("settings-choose-font")
        }
    }
}

extension SettingsView {
    /// The live pill over a wallpaper swatch, the swatch picker and the size caption.
    var appearancePreview: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    PillPreviewStageView(
                        kind: model.skin, size: model.pillSize, readout: model.readoutColour, wallpaper: model.previewWallpaper,
                        onStatus: { status in DispatchQueue.main.async { if model.previewStatus != status { model.previewStatus = status } } }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("\(model.skin.title) \u{00B7} live preview \u{00B7} \(model.pillSize.previewTitle) size".uppercased())
                        .font(DesignFont.mono(DesignFont.eyebrow)).tracking(DesignFont.eyebrowTracking)
                        .foregroundStyle(model.previewWallpaper.captionColor).padding(.bottom, 10).accessibilityHidden(true)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .topTrailing) { wallpaperPicker.padding(10) }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
                .preference(key: PreviewWidthKey.self, value: proxy.size.width)
            }.frame(height: 190)
            VStack(alignment: .leading, spacing: 2) {
                Text(PreviewFit.caption(size: model.pillSize, scale: PreviewFit.scale(availableWidth: previewWidth)))
                    .accessibilityIdentifier("settings-pill-size-caption")
                if let line = GlassPreviewCaption.text(model.previewStatus) {
                    Text(line).accessibilityIdentifier("settings-glass-caption")
                }
            }
            .font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 4)
        }
        .onPreferenceChange(PreviewWidthKey.self) { previewWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.skin.title) floating pill preview")
    }

    /// Light and Dark swatch buttons, drawn on the swatch itself so they stay readable over either one.
    private var wallpaperPicker: some View {
        let dark = model.previewWallpaper == .dark
        let ink: Color = dark ? .white : .black
        return HStack(spacing: 0) {
            ForEach(PreviewWallpaper.allCases) { wallpaper in
                let selected = wallpaper == model.previewWallpaper
                Button {
                    model.previewWallpaper = wallpaper
                } label: {
                    Text(wallpaper.title).font(DesignFont.sans(DesignFont.caption, .medium)).fixedSize()
                        .foregroundStyle(ink.opacity(selected ? 1 : 0.7))
                        .padding(.horizontal, 10).frame(minHeight: 24)
                        .background { if selected { RoundedRectangle(cornerRadius: 6).fill(ink.opacity(0.22)) } }
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("\(wallpaper.title) preview background").accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
        .padding(2).background(RoundedRectangle(cornerRadius: 8).fill(ink.opacity(0.12)))
        .accessibilityElement(children: .contain).accessibilityLabel("Preview background")
        .accessibilityIdentifier("settings-preview-wallpaper")
    }
}

private struct PreviewWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor enum SettingsPillImage {
    /// A settled still of the pill on the preview canvas, for a window that is not on screen, where a live skin never
    /// finishes its entrance. `.automatic` previews as Standard: the preview cannot know which screen the pill will land on.
    static func make(
        skin: PillSkinKind, size: PillSize, readout: PillReadoutColour = .default, wallpaper: PreviewWallpaper = .dark,
        glassEnvironment: GlassPillEnvironment = .system
    ) -> NSImage? {
        let canvas = PreviewFit.canvas
        let scale = size.resolved(visibleWidth: 0)
        let height = skin.pillHeight * scale.factor + 2 * PillGeometry.verticalMargin
        let frame = NSRect(x: 0, y: 0, width: canvas.width, height: height)
        guard let view = try? PillSkinFactory.make(skin, frame: frame, scale: scale, readout: readout, glassEnvironment: glassEnvironment) else { return nil }
        view.appearance = wallpaper.appearance
        view.appear(reduceMotion: true)
        view.showRecording(locked: false)
        view.showFractions(PreviewLevel.still)
        view.setElapsed(0)
        guard
            let context = CGContext(
                data: nil, width: Int(canvas.width * 2), height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.scaleBy(x: 2, y: 2)
        view.renderOffscreen(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: frame.size)
    }
}
