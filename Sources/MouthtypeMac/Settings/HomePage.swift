import SwiftUI
import MouthtypeCore

/// One day of takes on Home, newest day first.
struct HomeDayGroup: Identifiable, Equatable {
    var title: String
    var takes: [HomeTake]
    var id: String { title }

    /// Groups takes already sorted newest first. Today and Yesterday are named, older days show the date.
    static func group(_ takes: [HomeTake], now: Date = Date(), calendar: Calendar = .current) -> [HomeDayGroup] {
        var groups: [HomeDayGroup] = []
        var currentDay: Date?
        for take in takes {
            let day = calendar.startOfDay(for: take.startedAt)
            if day == currentDay, !groups.isEmpty {
                groups[groups.count - 1].takes.append(take)
            } else {
                currentDay = day
                groups.append(HomeDayGroup(title: title(for: take.startedAt, now: now, calendar: calendar), takes: [take]))
            }
        }
        return groups
    }

    static func title(for date: Date, now: Date, calendar: Calendar) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        let sameYear = calendar.isDate(date, equalTo: now, toGranularity: .year)
        return date.formatted(sameYear ? .dateTime.weekday(.wide).month(.wide).day() : .dateTime.month(.wide).day().year())
    }
}

/// The Home page: recent takes grouped by day, one card per day. Full text wraps, never truncates.
struct HomePage: View {
    var model: HomeLogModel

    var body: some View {
        content
            .onAppear { model.activate() }
            .onDisappear { model.deactivate() }
    }

    @ViewBuilder private var content: some View {
        if model.takes.isEmpty {
            DesignSection(eyebrow: "Recent takes") {
                Text(model.error ?? "No dictations yet. Hold your shortcut and talk, and they land here.")
                    .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(14)
            }
        } else {
            ForEach(HomeDayGroup.group(model.takes)) { group in
                DesignSection(eyebrow: group.title) {
                    ForEach(group.takes) { take in HomeTakeRow(take: take, model: model) }
                }
            }
        }
    }
}

struct HomeTakeRow: View {
    private enum Action { case copy, recover }

    let take: HomeTake
    var model: HomeLogModel
    @State private var hovering = false
    @FocusState private var focused: Action?

    private var showsActions: Bool {
        hovering || focused != nil || take.text == nil || model.lastCopiedID == take.id
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Self.time(take)).font(DesignFont.mono(11)).foregroundStyle(DesignPalette.ink2)
                if let app = take.appName, !app.isEmpty {
                    Text(app).font(DesignFont.sans(11)).foregroundStyle(DesignPalette.ink3).fixedSize(horizontal: false, vertical: true)
                }
            }.frame(width: 72, alignment: .leading).padding(.top, 2)
            Text(take.text ?? "No transcript. The audio is saved.")
                .font(DesignFont.sans(DesignFont.body))
                .foregroundStyle(take.text == nil ? DesignPalette.ink3 : DesignPalette.ink)
                .lineSpacing(2)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 6) {
                if take.text != nil {
                    Button(model.lastCopiedID == take.id ? "Copied" : "Copy") { model.copy(take) }
                        .buttonStyle(.designSecondary).focused($focused, equals: .copy)
                        .accessibilityLabel("Copy this take")
                        .accessibilityIdentifier("home-copy-" + take.id)
                }
                if take.recoverable != nil {
                    Button("Recover") { model.recover(take) }
                        .buttonStyle(.designSecondary).focused($focused, equals: .recover)
                        .disabled(!model.recoverEnabled)
                        .accessibilityLabel("Recover this take from its saved audio")
                        .accessibilityIdentifier("home-recover-" + take.id)
                }
            }
            .fixedSize()
            .opacity(showsActions ? 1 : 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(hovering ? DesignPalette.hair2 : Color.clear)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
    }

    static func time(_ take: HomeTake) -> String {
        take.startedAt.formatted(date: .omitted, time: .shortened)
    }
}
