import AppKit
import SwiftUI
import MouthtypeCore

extension SettingsView {
    @ViewBuilder var appearance: some View {
        SettingsGroup(eyebrow: "FLOATING PILL") {
            VStack(spacing: 12) {
                if let image = SettingsPillImage.make(skin: model.skin, size: model.pillSize) {
                    Image(nsImage: image).interpolation(.none).accessibilityLabel("\(model.skin.title) floating pill preview")
                        .frame(height: 95)
                }
                Text("\(model.skin.title) · floating pill").font(SettingsFont.mono(SettingsFont.eyebrow)).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity).padding(.vertical, 8)
            Picker("Pill style", selection: Binding(get: { model.skin.rawValue }, set: { if let skin = PillSkinKind(rawValue: $0) { model.setSkin(skin) } })) {
                ForEach(PillSkinKind.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
            }.pickerStyle(.segmented)
            SettingsRow(title: "Pill size", detail: "Automatic picks Large on wide screens. Applies the next time the pill appears.") {
                Picker("Pill size", selection: Binding(get: { model.pillSize.rawValue }, set: { if let size = PillSize(rawValue: $0) { model.setPillSize(size) } })) {
                    ForEach(PillSize.allCases, id: \.rawValue) { Text($0.title).tag($0.rawValue) }
                }.labelsHidden().fixedSize()
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

@MainActor enum SettingsPillImage {
    /// `.automatic` previews as Standard: the preview cannot know which screen the pill will land on.
    static func make(skin: PillSkinKind, size: PillSize) -> NSImage? {
        let frame = NSRect(x: 0, y: 0, width: 360, height: 110)
        let scale = size.resolved(visibleWidth: 0)
        let view: any PillSkinView
        if skin == .hifi, let assets = try? PillAssets.loadHiFi() { view = HiFiPillView(frame: frame, assets: assets, size: scale) }
        else { view = ClassicPillView(frame: frame, size: scale) }
        view.appear(reduceMotion: true)
        view.showRecording(locked: true)
        view.showFractions([0.2, 0.4, 0.6, 0.8, 0.5, 0.35, 0.65, 0.3, 0.2, 0.1])
        guard let context = CGContext(data: nil, width: 720, height: 220, bitsPerComponent: 8, bytesPerRow: 0,
                                     space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.scaleBy(x: 2, y: 2)
        view.layer?.render(in: context)
        guard let image = context.makeImage() else { return nil }
        return NSImage(cgImage: image, size: frame.size)
    }
}
