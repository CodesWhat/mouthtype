import SwiftUI

/// The five pill styles as picture tiles, drawn like the handoff's Style board: a wallpaper swatch with a miniature pill, the name
/// under it, and an accent ring on the selected one. Each tile is a button so Space picks it, and Left and Right step through them.
struct AppearanceStylePicker: View {
    let selection: PillSkinKind
    let onSelect: (PillSkinKind) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            DesignEyebrow("Style")
            HStack(spacing: 12) {
                ForEach(PillSkinKind.allCases, id: \.rawValue) { skin in
                    AppearanceStyleTile(skin: skin, selected: skin == selection) { onSelect(skin) }
                }
            }
            .onKeyPress(.leftArrow) { step(-1) }
            .onKeyPress(.rightArrow) { step(1) }
            .accessibilityElement(children: .contain).accessibilityLabel("Pill style")
            .accessibilityIdentifier("settings-pill-style")
        }
    }

    private func step(_ offset: Int) -> KeyPress.Result {
        let all = PillSkinKind.allCases
        guard let index = all.firstIndex(of: selection) else { return .ignored }
        let next = min(max(index + offset, 0), all.count - 1)
        if next != index { onSelect(all[next]) }
        return .handled
    }
}

private struct AppearanceStyleTile: View {
    @Environment(\.colorScheme) private var scheme
    let skin: PillSkinKind
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 8) {
                ZStack { AppearanceStyleArt(skin: skin) }
                    .frame(maxWidth: .infinity).frame(height: 62)
                    .background(RoundedRectangle(cornerRadius: 8).fill(AppearanceStyleArt.swatch(skin)))
                    .accessibilityHidden(true)
                HStack(spacing: 6) {
                    Text(skin.title).font(DesignFont.sans(12.5, .medium)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                    if selected {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .bold)).foregroundStyle(DesignPalette.accent).accessibilityHidden(true)
                    }
                }
                .frame(maxWidth: .infinity)
            }
            .padding(.horizontal, 8).padding(.top, 8).padding(.bottom, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            .overlay { if selected { RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.accent, lineWidth: 1.5) } }
            .shadow(color: DesignPalette.shadowColor(dark: scheme == .dark), radius: 0.5, y: 1)
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(skin.title) pill style")
        .accessibilityAddTraits(selected ? .isSelected : [])
        .accessibilityIdentifier("settings-pill-style-" + skin.rawValue)
    }
}

/// The miniature pill for each style, in fixed colours because it sits on a drawn swatch rather than on the page.
private struct AppearanceStyleArt: View {
    let skin: PillSkinKind

    static func swatch(_ skin: PillSkinKind) -> Color {
        switch skin {
        case .classic, .matrix, .hifi: Color(red: 0x3A / 255, green: 0x3A / 255, blue: 0x40 / 255)
        case .glass: Color(red: 0xB9 / 255, green: 0xBE / 255, blue: 0xC8 / 255)
        case .minimal: Color(red: 0xDA / 255, green: 0xDB / 255, blue: 0xE0 / 255)
        }
    }

    private static let mint = Color(red: 0x8F / 255, green: 0xC1 / 255, blue: 0xB5 / 255)
    private static let deepGreen = Color(red: 0x31 / 255, green: 0x5B / 255, blue: 0x54 / 255)
    private static let amber = Color(red: 1, green: 0xB3 / 255, blue: 0x27 / 255)
    private static let bars: [CGFloat] = [4, 8, 10, 6, 9, 5]

    var body: some View {
        switch skin {
        case .classic: capsule(fill: Color(red: 0x1C / 255, green: 0x1C / 255, blue: 0x1E / 255), bar: Self.mint, stroke: nil)
        case .glass: capsule(fill: .white.opacity(0.55), bar: Self.deepGreen, stroke: .white.opacity(0.9))
        case .matrix: matrix
        case .minimal: minimal
        case .hifi: hifi
        }
    }

    private func capsule(fill: Color, bar: Color, stroke: Color?) -> some View {
        HStack(spacing: 6) {
            HStack(alignment: .bottom, spacing: 1.5) {
                ForEach(Self.bars.indices, id: \.self) { Rectangle().fill(bar).frame(width: 2, height: Self.bars[$0]) }
            }.frame(height: 10)
            Circle().fill(Color(red: 0xFC / 255, green: 0xFC / 255, blue: 0xFB / 255)).frame(width: 13, height: 13)
        }
        .padding(.leading, 9).padding(.trailing, 5).frame(height: 22)
        .background(Capsule().fill(fill))
        .overlay { if let stroke { Capsule().strokeBorder(stroke, lineWidth: 1) } }
        .shadow(color: .black.opacity(stroke == nil ? 0 : 0.12), radius: 3, y: 2)
    }

    private var matrix: some View {
        let grid: [[Bool]] = ["1011010", "0110110", "1101011"].map { $0.map { $0 == "1" } }
        return HStack(spacing: 6) {
            Circle().fill(Color(red: 1, green: 0x4A / 255, blue: 0x3C / 255)).frame(width: 5, height: 5)
            VStack(spacing: 1.5) {
                ForEach(grid.indices, id: \.self) { row in
                    HStack(spacing: 1.5) {
                        ForEach(grid[row].indices, id: \.self) { col in
                            Rectangle().fill(Self.amber.opacity(grid[row][col] ? 1 : 0.15)).frame(width: 3, height: 3)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 8).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0x19 / 255, green: 0x19 / 255, blue: 0x1B / 255)))
    }

    private var minimal: some View {
        let ink = Color(red: 0x1D / 255, green: 0x1D / 255, blue: 0x1F / 255)
        return HStack(spacing: 6) {
            Circle().fill(Color(red: 0xE0 / 255, green: 0x28 / 255, blue: 0x1C / 255)).frame(width: 5, height: 5)
            HStack(spacing: 2) {
                ForEach(Array([4, 8, 10, 6, 9, 5, 7].enumerated()), id: \.offset) { Rectangle().fill(ink).frame(width: 1.5, height: CGFloat($0.element)) }
            }.frame(height: 10)
        }
        .padding(.horizontal, 9).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color(red: 0xFB / 255, green: 0xFB / 255, blue: 0xFC / 255)))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.black.opacity(0.16), lineWidth: 0.5))
    }

    private var hifi: some View {
        Text("REC 0:07").font(DesignFont.mono(9)).tracking(0.7).foregroundStyle(Self.amber).fixedSize()
            .padding(.horizontal, 8).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 3).fill(Color(red: 0x2A / 255, green: 0x26 / 255, blue: 0x22 / 255)))
            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color(red: 0x4A / 255, green: 0x40 / 255, blue: 0x38 / 255), lineWidth: 1))
    }
}
