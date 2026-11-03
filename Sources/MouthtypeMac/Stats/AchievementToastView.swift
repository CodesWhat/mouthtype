import AppKit
import MouthtypeCore
import SwiftUI

/// The trophy toast, drawn in the bottom trailing corner of the Mouthtype window and nowhere else. Never a panel, never a system
/// notification: it is a view inside the window, so it cannot sit over the pill or appear while dictating elsewhere.
struct AchievementToastHost: View {
    var center: AchievementToastCenter
    var skin: PillSkinKind
    var readout: PillReadoutColour
    var scale: PillScale = .standard

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            if let toast = center.current {
                AchievementToastView(center: center, toast: toast, skin: skin, readout: readout, scale: scale)
                    .id(toast.id)
                    .transition(toast.slides ? .move(edge: .bottom).combined(with: .opacity) : .opacity)
            }
        }
        .padding(.trailing, 14).padding(.bottom, 14)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .animation(.easeOut(duration: (center.current?.slides ?? true) ? 0.28 : 0.15), value: center.current?.id)
    }
}

/// One toast: Hi-Fi draws its own pixel window when the pixel faces can show the words, every other skin the Classic toast.
struct AchievementToastView: View {
    var center: AchievementToastCenter
    let toast: AchievementToast
    var skin: PillSkinKind
    var readout: PillReadoutColour
    var scale: PillScale = .standard

    @State private var hovering = false
    @FocusState private var focus: Control?

    enum Control: Hashable { case open, close }

    var body: some View {
        content
            .onHover { hovering = $0 }
            .onChange(of: hovering || focus != nil) { _, held in center.setPaused(held) }
            .onKeyPress(.escape) {
                center.dismiss()
                return .handled
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(toast.accessibilityLabel)
    }

    @ViewBuilder private var content: some View {
        if skin == .hifi, let assets = HiFiCardAssets.shared {
            HiFiToastBody(center: center, toast: toast, assets: assets, readout: readout, scale: scale, focus: $focus)
        } else {
            ClassicToastBody(center: center, toast: toast, skin: skin, focus: $focus)
        }
    }
}

/// The Classic look, in the skin's palette: the delivery card's squared-off body, the cup, the name in the serif face, the line,
/// a close button, and a thin bar that runs down over the six seconds.
private struct ClassicToastBody: View {
    var center: AchievementToastCenter
    let toast: AchievementToast
    var skin: PillSkinKind
    var focus: FocusState<AchievementToastView.Control?>.Binding

    private var accent: Color { skin == .matrix ? Color(nsColor: CardPalette.amber) : DesignPalette.accentText }
    private var bar: Color { skin == .matrix ? Color(nsColor: CardPalette.amber) : DesignPalette.accentMark }

    var body: some View {
        VStack(spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Button(action: { center.open() }) {
                    HStack(alignment: .center, spacing: 10) {
                        TrophyImage(spriteID: toast.spriteID ?? "", face: .earned(toast.tier), scale: 2)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(toast.kicker.uppercased()).font(DesignFont.mono(DesignFont.eyebrow)).tracking(DesignFont.eyebrowTracking)
                                .foregroundStyle(accent)
                            Text(toast.title).font(DesignFont.serif(DesignFont.display)).foregroundStyle(DesignPalette.ink)
                                .fixedSize(horizontal: false, vertical: true)
                            Text(toast.body).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain).focused(focus, equals: .open)
                .accessibilityLabel(toast.accessibilityLabel).accessibilityHint("Opens the trophy shelf")
                Button(action: { center.dismiss() }) {
                    Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).foregroundStyle(DesignPalette.ink2)
                        .frame(width: 26, height: 26).background(RoundedRectangle(cornerRadius: 8).fill(DesignPalette.sel))
                        .contentShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain).focused(focus, equals: .close).accessibilityLabel("Dismiss")
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
                let fraction = center.fractionLeft(at: timeline.date)
                GeometryReader { proxy in
                    ZStack(alignment: .leading) {
                        Capsule().fill(DesignPalette.track)
                        Capsule().fill(bar).frame(width: proxy.size.width * fraction)
                    }
                }
            }
            .frame(height: 3).accessibilityHidden(true)
        }
        .padding(.leading, 12).padding(.trailing, 14).padding(.vertical, 12)
        .frame(width: 318)
        .fixedSize(horizontal: true, vertical: true)
        .background {
            RoundedRectangle(cornerRadius: 14).fill(skin == .glass ? AnyShapeStyle(.regularMaterial) : AnyShapeStyle(DesignPalette.surface))
        }
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(DesignPalette.hair, lineWidth: 1))
        .shadow(color: .black.opacity(0.28), radius: 14, y: 6)
    }
}

/// The Hi-Fi toast: the composed pixel window at a whole-number scale, with the open and close targets laid over it. Falls back
/// to the Classic toast when the pixel faces cannot draw the words as written.
private struct HiFiToastBody: View {
    var center: AchievementToastCenter
    let toast: AchievementToast
    let assets: HiFiCardAssets
    var readout: PillReadoutColour
    var scale: PillScale
    var focus: FocusState<AchievementToastView.Control?>.Binding

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.1)) { timeline in
            let fraction = center.fractionLeft(at: timeline.date)
            if let face = HiFiAchievementToast.compose(toast: toast, assets: assets, readout: readout, fraction: fraction) {
                let k = scale.factor
                let size = CGSize(width: CGFloat(face.frames.width) * k, height: CGFloat(face.frames.height) * k)
                let hit = face.frames.closeHit
                Image(decorative: face.image, scale: 1).resizable().interpolation(.none).frame(width: size.width, height: size.height)
                    .overlay {
                        Button(action: { center.open() }) { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain).focused(focus, equals: .open)
                            .accessibilityLabel(toast.accessibilityLabel).accessibilityHint("Opens the trophy shelf")
                    }
                    .overlay(alignment: .topLeading) {
                        Button(action: { center.dismiss() }) { Color.clear.contentShape(Rectangle()) }
                            .buttonStyle(.plain).focused(focus, equals: .close).accessibilityLabel("Dismiss")
                            .frame(width: CGFloat(hit.w) * k, height: CGFloat(hit.h) * k)
                            .offset(x: CGFloat(hit.x) * k, y: CGFloat(hit.y) * k)
                    }
                    .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
            } else {
                ClassicToastBody(center: center, toast: toast, skin: .classic, focus: focus)
            }
        }
    }
}
