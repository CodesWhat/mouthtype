import AppKit
import MouthtypeCore
import SwiftUI

/// A pixel trophy cup drawn from its template at whole pixels, scaled up with smoothing off. Decorative: the tile carries the label.
struct TrophyImage: View {
    @Environment(\.colorScheme) private var scheme
    let spriteID: String
    let face: TrophyArt.Face
    var scale: CGFloat = 2

    var body: some View {
        let canvas = TrophyArt.canvas(spriteID: spriteID, face: face, dark: scheme == .dark)
        Group {
            if let image = canvas.image {
                Image(decorative: image, scale: 1).resizable().interpolation(.none)
            } else {
                Color.clear
            }
        }
        .frame(width: CGFloat(TrophyArt.width) * scale, height: CGFloat(TrophyArt.height) * scale)
        .accessibilityHidden(true)
    }
}

/// Equal-width tiles in as many columns as fit, every tile in a row as tall as the tallest.
struct AchievementFlow: Layout {
    static let minimumTileWidth: CGFloat = 210
    static let spacing: CGFloat = 10

    static func columns(for width: CGFloat) -> Int {
        max(1, Int((width + spacing) / (minimumTileWidth + spacing)))
    }

    private func rows(_ subviews: Subviews, width: CGFloat) -> (tile: CGFloat, heights: [CGFloat], columns: Int) {
        let columns = Self.columns(for: width)
        let tile = (width - Self.spacing * CGFloat(columns - 1)) / CGFloat(columns)
        var heights: [CGFloat] = []
        var index = 0
        while index < subviews.count {
            let row = subviews[index..<min(subviews.count, index + columns)]
            heights.append(row.map { $0.sizeThatFits(ProposedViewSize(width: tile, height: nil)).height }.max() ?? 0)
            index += columns
        }
        return (tile, heights, columns)
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.minimumTileWidth * 3
        let layout = rows(subviews, width: width)
        let height = layout.heights.reduce(0, +) + Self.spacing * CGFloat(max(0, layout.heights.count - 1))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let layout = rows(subviews, width: bounds.width)
        var y = bounds.minY
        for (rowIndex, height) in layout.heights.enumerated() {
            for column in 0..<layout.columns {
                let index = rowIndex * layout.columns + column
                guard index < subviews.count else { break }
                subviews[index].place(
                    at: CGPoint(x: bounds.minX + CGFloat(column) * (layout.tile + Self.spacing), y: y), anchor: .topLeading,
                    proposal: ProposedViewSize(width: layout.tile, height: height))
            }
            y += height + Self.spacing
        }
    }
}

/// The dim tile background of a locked trophy.
private let lockedTile = Color(
    nsColor: NSColor(name: nil) { appearance in
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            ? NSColor(srgbRed: 0x32 / 255, green: 0x32 / 255, blue: 0x35 / 255, alpha: 1)
            : NSColor(srgbRed: 0xEC / 255, green: 0xEC / 255, blue: 0xEF / 255, alpha: 1)
    })

struct AchievementTile: View {
    let entry: AchievementShelfEntry
    let today: String

    private var isEarned: Bool { if case .earned = entry.state { true } else { false } }

    private var face: TrophyArt.Face {
        switch entry.state {
        case .earned: .earned(entry.tier)
        case .locked: .locked
        case .hidden: .hidden
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            TrophyImage(spriteID: entry.id, face: face)
            VStack(alignment: .leading, spacing: 2) {
                nameLine
                detail
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 11).padding(.vertical, 10)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 12).fill(isEarned ? DesignPalette.surface : lockedTile))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(entry.isNew ? DesignPalette.accentMark : DesignPalette.hair2, lineWidth: 1))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.accessibilityLabel(entry, today: today))
    }

    private var nameLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title).font(DesignFont.sans(13, .semibold)).foregroundStyle(isEarned ? DesignPalette.ink : DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if entry.isNew {
                Text("NEW").font(DesignFont.mono(DesignFont.eyebrow).weight(.bold)).tracking(1)
                    .foregroundStyle(DesignPalette.onAccent)
                    .padding(.horizontal, 5).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(DesignPalette.accent))
            }
        }
    }

    private var title: String { entry.state == .hidden ? "Hidden" : entry.name }

    @ViewBuilder private var detail: some View {
        switch entry.state {
        case .earned:
            Text(entry.copy).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            Text(Self.earnedText(entry, today: today)).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.5).textCase(.uppercase)
                .foregroundStyle(DesignPalette.ink3).fixedSize(horizontal: false, vertical: true).padding(.top, 3)
        case .locked(let progress):
            Text(progress.line).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
            if progress.fraction > 0 { bar(progress.fraction) }
        case .hidden:
            Text("Keep talking.").font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
        }
    }

    /// Never animated, so Reduce Motion needs nothing.
    private func bar(_ fraction: Double) -> some View {
        RoundedRectangle(cornerRadius: 2).fill(DesignPalette.track).frame(height: 4)
            .overlay(alignment: .leading) {
                GeometryReader { proxy in
                    RoundedRectangle(cornerRadius: 2).fill(DesignPalette.accentMark).frame(width: max(3, proxy.size.width * fraction))
                }
            }
            .padding(.top, 5)
    }

    static func earnedText(_ entry: AchievementShelfEntry, today: String) -> String {
        guard case .earned(let day) = entry.state else { return "" }
        if entry.isApproximate || day == nil { return "Earned before trophies" }
        return "Earned \(StatsFormat.recordDate(day ?? "", today: today))"
    }

    /// Name, tier, the line of copy, and the earned date or the progress.
    static func accessibilityLabel(_ entry: AchievementShelfEntry, today: String) -> String {
        let tier = entry.tier.rawValue
        let tag = entry.isNew ? ", new" : ""
        switch entry.state {
        case .earned:
            return "\(entry.name), \(tier), \(earnedText(entry, today: today).lowercased())\(tag). \(entry.copy)"
        case .locked(let progress):
            return "\(entry.name), \(tier), locked. \(progress.line)"
        case .hidden:
            return "Hidden trophy, locked. Keep talking."
        }
    }
}

/// The trophy shelf: a card at the bottom of Stats, grouped tiles, with a control to hide it.
struct AchievementShelfCard: View {
    let model: AchievementModel
    let today: String
    /// With no takes yet: the first three tiles and a line, instead of every group.
    var isEmptyState = false

    var body: some View {
        if model.isEnabled, !model.entries.isEmpty {
            StatsCard {
                VStack(alignment: .leading, spacing: 12) {
                    header
                    if !model.isShelfHidden { shelf }
                }
            }
            .onDisappear { model.shelfSeen() }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 8) {
            TrophyImage(spriteID: "", face: .earned(.gold), scale: 1)
            if model.isShelfHidden {
                Text("Trophies hidden.").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                Button("Show") { model.setShelfHidden(false) }.buttonStyle(.designSecondary).fixedSize()
                    .accessibilityLabel("Show trophies").accessibilityIdentifier("stats-show-trophies")
            } else {
                Text("Trophies  ·  \(model.earnedCount) of \(model.entries.count)").designEyebrow()
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                Button("Hide trophies") { model.setShelfHidden(true) }.buttonStyle(.designSecondary).fixedSize()
                    .accessibilityIdentifier("stats-hide-trophies")
            }
        }
    }

    @ViewBuilder private var shelf: some View {
        if isEmptyState {
            AchievementFlow {
                ForEach(model.entries.filter { !$0.isHidden }.prefix(3)) { AchievementTile(entry: $0, today: today) }
            }
            Text("Nothing yet. Your first take earns one.").font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            ForEach(AchievementGroup.allCases, id: \.self) { group in
                let tiles = model.entries.filter { $0.group == group }
                if !tiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(group.title).designEyebrow().frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.bottom, 6).overlay(alignment: .bottom) { DesignHairline() }
                        AchievementFlow {
                            ForEach(tiles) { AchievementTile(entry: $0, today: today) }
                        }
                    }
                }
            }
            Text("Turn trophies off in Settings, Mac. Cup colour is the tier: bronze, silver, gold.")
                .font(DesignFont.sans(11)).foregroundStyle(DesignPalette.ink3).fixedSize(horizontal: false, vertical: true)
        }
    }
}

private extension AchievementShelfEntry {
    /// A hidden-kind trophy, earned or not.
    var isHidden: Bool { group == .hidden }
}
