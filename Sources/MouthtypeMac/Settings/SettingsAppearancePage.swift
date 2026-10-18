import AppKit
import SwiftUI
import MouthtypeCore

extension SettingsView {
    @ViewBuilder var appearance: some View {
        SettingsGroup(eyebrow: "FLOATING PILL") {
            appearancePreview
            SettingsRow(title: "Pill style") {
                Picker("Pill style", selection: Binding(get: { model.skin.rawValue }, set: { if let skin = PillSkinKind(rawValue: $0) { model.setSkin(skin) } })) {
                    ForEach(PillSkinKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("settings-pill-style")
            }
            SettingsRow(title: "Pill size", detail: "Automatic picks Large on wide screens. Applies the next time the pill appears.") {
                Picker("Pill size", selection: Binding(get: { model.pillSize.rawValue }, set: { if let size = PillSize(rawValue: $0) { model.setPillSize(size) } })) {
                    ForEach(PillSize.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().fixedSize().accessibilityIdentifier("settings-pill-size")
            }
            if model.skin == .hifi {
                SettingsRow(title: "Readout colour", detail: "The Hi-Fi meter, timer and message text.") {
                    Circle().fill(Color(cgColor: PillLayout.color(hex: model.readoutColour.swatchHex))).frame(width: 9, height: 9)
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)).accessibilityHidden(true)
                    Picker("Readout colour", selection: Binding(get: { model.readoutColour.rawValue }, set: { if let colour = PillReadoutColour(rawValue: $0) { model.setReadoutColour(colour) } })) {
                        ForEach(PillReadoutColour.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                    }.labelsHidden().fixedSize().accessibilityIdentifier("settings-readout-colour")
                }
            }
        }
        SettingsGroup(eyebrow: "TEXT") {
            SettingsRow(title: model.fontOverrides.enabled ? "Base text font" : "Text font", detail: "Used by the Classic pill and delivery cards.") {
                Picker("Text font", selection: Binding(get: { model.font.title }, set: { name in if let font = TextFontChoice.standard.first(where: { $0.title == name }) { model.setFont(font) } })) {
                    ForEach(TextFontChoice.standard, id: \.title) { Text($0.title).tag($0.title) }
                    if case .custom = model.font { Text(model.font.title).tag(model.font.title) }
                }.labelsHidden().fixedSize()
                Button("Choose Font…", action: actions.chooseFont)
            }
        }
        FontOverridesSection(model: model)
    }
}

extension SettingsView {
    /// The live pill over a wallpaper swatch, the swatch picker and the size caption.
    var appearancePreview: some View {
        VStack(spacing: 8) {
            GeometryReader { proxy in
                ZStack(alignment: .bottom) {
                    PillPreviewStageView(kind: model.skin, size: model.pillSize, readout: model.readoutColour, wallpaper: model.previewWallpaper,
                                         onStatus: { status in DispatchQueue.main.async { if model.previewStatus != status { model.previewStatus = status } } })
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Text("\(model.skin.title) · live preview".uppercased()).font(SettingsFont.mono(SettingsFont.eyebrow)).tracking(1)
                        .foregroundStyle(model.previewWallpaper.captionColor).shadow(color: model.previewWallpaper.captionShadow, radius: 2).padding(.bottom, 6).accessibilityHidden(true)
                }
                .frame(width: proxy.size.width, height: proxy.size.height)
                .overlay(alignment: .topTrailing) { wallpaperPicker.padding(8) }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
                .preference(key: PreviewWidthKey.self, value: proxy.size.width)
            }.frame(height: 156)
            VStack(alignment: .leading, spacing: 2) {
                Text(PreviewFit.caption(size: model.pillSize, scale: PreviewFit.scale(availableWidth: previewWidth)))
                    .accessibilityIdentifier("settings-pill-size-caption")
                if let line = GlassPreviewCaption.text(model.previewStatus) {
                    Text(line).accessibilityIdentifier("settings-glass-caption")
                }
            }
            .font(SettingsFont.sans(SettingsFont.detail)).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, alignment: .leading)
        }
        .onPreferenceChange(PreviewWidthKey.self) { previewWidth = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(model.skin.title) floating pill preview")
    }

    private var wallpaperPicker: some View {
        Picker("Preview background", selection: $model.previewWallpaper) {
            ForEach(PreviewWallpaper.allCases) { Text($0.title).tag($0) }
        }.labelsHidden().pickerStyle(.segmented).fixedSize().accessibilityIdentifier("settings-preview-wallpaper")
    }
}

private struct PreviewWidthKey: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

@MainActor enum SettingsPillImage {
    /// A settled still of the pill on the preview canvas, for a window that is not on screen, where a live skin never
    /// finishes its entrance. `.automatic` previews as Standard: the preview cannot know which screen the pill will land on.
    static func make(skin: PillSkinKind, size: PillSize, readout: PillReadoutColour = .default, wallpaper: PreviewWallpaper = .dark,
                     glassEnvironment: GlassPillEnvironment = .system) -> NSImage? {
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
        guard let context = CGContext(data: nil, width: Int(canvas.width * 2), height: Int(height * 2), bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        view.renderOffscreen(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: frame.size)
    }
}
