import SwiftUI
import MouthtypeCore

/// The Stats sidebar page: live numbers from the model, or a plain empty state when there is no history yet. Records live on
/// this page now, as the High scores card.
struct StatsHostPage: View {
    var model: StatsModel

    /// Today's tape shows whenever there is a take today, even when the history is only audio with no transcript.
    static func showsTape(_ snapshot: StatsSnapshot) -> Bool { !snapshot.todayTakes.isEmpty }

    var body: some View {
        if let snapshot = model.snapshot, snapshot.hasHistory {
            // Once a minute, so the NOW marker on the tape keeps up without a reload.
            TimelineView(.periodic(from: .now, by: 60)) { context in
                StatsPage(snapshot: snapshot, now: context.date)
            }
        } else {
            VStack(alignment: .leading, spacing: 16) {
                if let snapshot = model.snapshot, Self.showsTape(snapshot) {
                    TimelineView(.periodic(from: .now, by: 60)) { context in
                        StatsTapeCard(takes: snapshot.todayTakes, nowSeconds: StatsTimeline.secondsIntoDay(of: context.date, in: .autoupdatingCurrent),
                                      typingWPM: snapshot.report.typingWPM)
                    }
                }
                DesignSection(eyebrow: "STATS") {
                    Text(model.error ?? "No stats yet. Dictate something and your numbers show up here.")
                        .font(DesignFont.sans(DesignFont.body)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true).padding(16)
                }
            }
        }
    }
}

/// The redesigned Stats cards, from one `StatsSnapshot`. Nothing is shortened: text wraps and cards grow.
struct StatsPage: View {
    let snapshot: StatsSnapshot
    var now: Date = Date()
    var timeZone: TimeZone = .autoupdatingCurrent

    private var report: StatsReport { snapshot.report }
    private var today: String { StatsTimeline.localDay(for: now, in: timeZone) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            StatsHeroCard(report: report)
            StatsTapeCard(takes: snapshot.todayTakes, nowSeconds: nowSeconds, typingWPM: report.typingWPM)
            pair(left: { StatsSpeedCard(report: report) },
                 right: { StatsStreakCard(daily: snapshot.daily, current: report.currentStreakDays, longest: report.longestStreakDays) })
            pair(left: { StatsDayCard(hourly: snapshot.hourlyWords) },
                 right: { StatsHighScoresCard(records: snapshot.records, today: today) })
            Text("Worked out on this Mac. Nothing is sent anywhere.")
                .font(DesignFont.sans(11)).foregroundStyle(DesignPalette.ink3)
                .fixedSize(horizontal: false, vertical: true).padding(.leading, 4)
                .help("Everything here is worked out on this Mac from your own log. Nothing is shared or sent anywhere, and takes from password fields are never counted.")
        }
    }

    private var nowSeconds: Int { StatsTimeline.secondsIntoDay(of: now, in: timeZone) }

    private func pair<Left: View, Right: View>(@ViewBuilder left: () -> Left, @ViewBuilder right: () -> Right) -> some View {
        StatsPair { left(); right() }
    }
}

/// Two cards side by side with equal widths, stacked when the page is too narrow for both.
struct StatsPair: Layout {
    static let sideBySideWidth: CGFloat = 620
    static let spacing: CGFloat = 12

    private func sideBySide(_ proposal: ProposedViewSize) -> Bool { (proposal.width ?? Self.sideBySideWidth) >= Self.sideBySideWidth }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? Self.sideBySideWidth
        if sideBySide(proposal) {
            let each = (width - Self.spacing) / 2
            let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: each, height: nil)).height }
            return CGSize(width: width, height: heights.max() ?? 0)
        }
        let heights = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)).height }
        return CGSize(width: width, height: heights.reduce(0, +) + Self.spacing * CGFloat(max(0, subviews.count - 1)))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        if sideBySide(ProposedViewSize(width: bounds.width, height: nil)) {
            let each = (bounds.width - Self.spacing) / 2
            for (index, view) in subviews.enumerated() {
                view.place(at: CGPoint(x: bounds.minX + CGFloat(index) * (each + Self.spacing), y: bounds.minY), anchor: .topLeading,
                           proposal: ProposedViewSize(width: each, height: bounds.height))
            }
        } else {
            var y = bounds.minY
            for view in subviews {
                let height = view.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil)).height
                view.place(at: CGPoint(x: bounds.minX, y: y), anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: height))
                y += height + Self.spacing
            }
        }
    }
}

// MARK: Card chrome

struct StatsCard<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    var padding = EdgeInsets(top: 16, leading: 20, bottom: 14, trailing: 20)
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(padding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(DesignPalette.surface))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            .shadow(color: DesignPalette.shadowColor(dark: scheme == .dark), radius: 0.5, y: 1)
    }
}

@MainActor private func monoLine(_ text: String) -> some View {
    Text(text).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).foregroundStyle(DesignPalette.ink3)
        .fixedSize(horizontal: false, vertical: true)
}

/// "VALUE LABEL" in the mono readout style: ink value, secondary label.
@MainActor private func readout(_ value: String, _ label: String) -> some View {
    (Text(value).foregroundStyle(DesignPalette.ink) + Text(" \(label)").foregroundStyle(DesignPalette.ink2))
        .font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).textCase(.uppercase)
        .fixedSize(horizontal: false, vertical: true)
}

// MARK: Hero

/// The all-time words flip counter with today, this week and the hours saved.
struct StatsHeroCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let report: StatsReport

    var body: some View {
        StatsCard(padding: EdgeInsets(top: 18, leading: 20, bottom: 18, trailing: 20)) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .center, spacing: 24) { counterBlock; Spacer(minLength: 0); savedBlock(alignment: .trailing) }
                VStack(alignment: .leading, spacing: 16) { counterBlock; savedBlock(alignment: .leading) }
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var counterBlock: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Words, all time").designEyebrow()
            FlipCounter(value: report.wordsAllTime, reduceMotion: reduceMotion)
            HStack(alignment: .top, spacing: 28) {
                figure("Today", StatsFormat.number(report.wordsToday))
                figure("This week", StatsFormat.number(report.wordsThisWeek))
                figure("Takes", StatsFormat.number(report.dictationCount))
            }
            .padding(.top, 2)
        }
        .help(report.firstDay.map { "Since \(StatsFormat.shortDay($0))" } ?? "")
        .accessibilityElement(children: .combine)
    }

    /// A mono eyebrow over a number.
    private func figure(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased()).font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).foregroundStyle(DesignPalette.ink3)
            Text(value).font(DesignFont.sans(14, .medium)).foregroundStyle(DesignPalette.ink)
        }
        .fixedSize()
    }

    private func savedBlock(alignment: HorizontalAlignment) -> some View {
        VStack(alignment: alignment, spacing: 4) {
            Text(StatsFormat.savedHeadline(minutes: report.minutesSaved))
                .font(DesignFont.serif(DesignFont.display)).foregroundStyle(DesignPalette.ink)
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .fixedSize(horizontal: false, vertical: true)
            monoLine("\(StatsFormat.talking(minutes: report.speakingMinutes)) TALKING")
                .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
                .help("Time saved is measured against typing at \(Int(report.typingWPM)) words per minute.")
        }
        .frame(maxWidth: 320, alignment: alignment == .trailing ? .trailing : .leading)
    }
}

/// One cell per digit with a seam through the middle, the last digit in the accent. The count changes without animation under
/// Reduce Motion.
struct FlipCounter: View {
    let value: Int
    let reduceMotion: Bool

    var body: some View {
        let text = StatsFormat.number(value)
        HStack(spacing: 4) {
            ForEach(Array(text.enumerated()), id: \.offset) { index, character in
                if character.isNumber {
                    cell(String(character), accent: index == text.count - 1)
                } else {
                    Text(String(character)).font(DesignFont.mono(24)).foregroundStyle(DesignPalette.ink3)
                        .frame(width: 10).padding(.top, 18).accessibilityHidden(true)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.3), value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(text) words")
    }

    private func cell(_ digit: String, accent: Bool) -> some View {
        Text(digit).font(DesignFont.mono(30).weight(.medium)).monospacedDigit()
            .contentTransition(reduceMotion ? .identity : .numericText())
            .foregroundStyle(accent ? DesignPalette.accent : DesignPalette.ink)
            .frame(width: 36, height: 48)
            .background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.bg))
            .overlay(Rectangle().fill(DesignPalette.hair).frame(height: 1))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignPalette.hair2, lineWidth: 1))
            .clipShape(RoundedRectangle(cornerRadius: 6))
    }
}

// MARK: Today's tape

/// The hours the tape spans: from a little before the day's first take (or now, if that is earlier) to a little after now or the
/// last take, never less than three hours, so a busy afternoon gets the room instead of a fixed 8 AM to 8 PM.
struct TapeRange: Equatable {
    static let minimumHours = 3
    var start: Int
    var end: Int

    init(takes: [TodayTake], nowSeconds: Int) {
        let first = min(takes.map(\.secondsIntoDay).min() ?? nowSeconds, nowSeconds)
        let last = max(takes.map(\.secondsIntoDay).max() ?? 0, nowSeconds)
        var lower = max(0, (first - 15 * 60) / 3_600)
        var upper = min(24, (last + 10 * 60 + 3_599) / 3_600)
        if upper - lower < Self.minimumHours {
            upper = min(24, lower + Self.minimumHours)
            lower = max(0, upper - Self.minimumHours)
        }
        start = lower
        end = upper
    }

    var span: Double { Double(end - start) * 3_600 }
    func fraction(_ seconds: Int) -> Double { min(1, max(0, Double(seconds - start * 3_600) / span)) }

    /// Hours that get a gridline and a label; the right edge is labelled separately.
    var ticks: [Int] {
        let hours = end - start
        let step = hours <= 6 ? 1 : (hours <= 12 ? 2 : (hours <= 18 ? 3 : 4))
        return stride(from: start, to: end, by: step).map { $0 }
    }

    static func label(_ hour: Int, edge: Bool) -> String {
        if hour == 12 { return "NOON" }
        if edge { return StatsFormat.hourName(hour) }
        return "\(hour % 12 == 0 ? 12 : hour % 12)"
    }
}

/// One needle on the tape: a single take, or several that would have landed closer together than the minimum spacing.
struct TapeSlot: Equatable {
    var x: Double
    var count: Int
    var words: Int
    /// Takes in the slot that saved audio but produced no transcript.
    var hollow: Int
    var firstSeconds: Int
    var lastSeconds: Int
    /// The take itself when the slot holds exactly one.
    var take: TodayTake?

    var isAllHollow: Bool { hollow == count }
    var hasHollowCap: Bool { hollow > 0 && hollow < count }

    /// "2:50 to 2:58 PM", or just "2:50 PM" for one moment.
    var timeLabel: String {
        let first = StatsFormat.clock(seconds: firstSeconds), last = StatsFormat.clock(seconds: lastSeconds)
        if first == last { return first }
        let firstPeriod = first.suffix(2), lastPeriod = last.suffix(2)
        return (firstPeriod == lastPeriod ? String(first.dropLast(3)) : first) + " to " + last
    }

    /// "3 takes · 412 words · 2:50 to 2:58 PM".
    var summary: String {
        var text = "\(count) \(count == 1 ? "take" : "takes") · \(StatsFormat.number(words)) words · \(timeLabel)"
        if hollow > 0 { text += " · \(hollow) audio only" }
        return text
    }
}

enum TapeSlots {
    static let minimumSpacing: Double = 6
    static let maximumHeight: Double = 44

    /// Takes in time order, grouped so no two slots start closer than `minSpacing` points apart at this width. Each slot sits where its
    /// first take falls, and its words are the sum.
    static func merge(_ takes: [TodayTake], range: TapeRange, width: Double, minSpacing: Double = minimumSpacing) -> [TapeSlot] {
        var slots: [TapeSlot] = []
        for take in takes.sorted(by: { $0.secondsIntoDay < $1.secondsIntoDay }) {
            let x = width * range.fraction(take.secondsIntoDay)
            if var last = slots.last, x - last.x < minSpacing {
                last.count += 1
                last.words += take.words
                last.hollow += take.hasTranscript ? 0 : 1
                last.lastSeconds = take.secondsIntoDay
                last.take = nil
                slots[slots.count - 1] = last
            } else {
                slots.append(TapeSlot(x: x, count: 1, words: take.words, hollow: take.hasTranscript ? 0 : 1,
                                      firstSeconds: take.secondsIntoDay, lastSeconds: take.secondsIntoDay, take: take))
            }
        }
        return slots
    }

    /// Square-root scale so one long take doesn't flatten the rest. Still strictly taller for more words.
    static func height(words: Int, maxWords: Int) -> Double {
        guard words > 0 else { return 8 }
        return 4 + (maximumHeight - 4) * (Double(words) / Double(max(1, maxWords))).squareRoot()
    }
}

struct StatsTapeCard: View {
    let takes: [TodayTake]
    let nowSeconds: Int
    let typingWPM: Double
    @State private var hovered: Int?

    private var range: TapeRange { TapeRange(takes: takes, nowSeconds: nowSeconds) }

    var body: some View {
        let summary = TodaySummary(takes: takes, typingWPM: typingWPM)
        StatsCard {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Text("Today's tape").designEyebrow()
                    Spacer(minLength: 0)
                    monoLine("TALLER = MORE WORDS")
                }
                tape.padding(.top, 14)
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .center, spacing: 14) { readouts(summary); Spacer(minLength: 0); legend }
                    VStack(alignment: .leading, spacing: 8) { HStack(spacing: 14) { readouts(summary) }; legend }
                    VStack(alignment: .leading, spacing: 8) { readouts(summary); legend }
                }
            }
        }
        .help("Every take as a needle at its time of day. Takes closer together than the needles can show are merged, and their words added.")
    }

    @ViewBuilder private func readouts(_ summary: TodaySummary) -> some View {
        readout("\(summary.takes)", summary.takes == 1 ? "take" : "takes")
        divider
        readout(StatsFormat.number(summary.words), "words")
        divider
        readout(StatsFormat.talking(ms: summary.speakingMs), "talking")
        divider
        readout(StatsFormat.talking(minutes: summary.minutesAvoided), "of typing avoided")
    }

    private var legend: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(DesignPalette.surface)
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(DesignPalette.accent, lineWidth: 1.5))
                .frame(width: 8, height: 8)
            Text("AUDIO SAVED, NO TRANSCRIPT").font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8)
                .foregroundStyle(DesignPalette.ink2).fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHidden(true)
    }

    private var divider: some View {
        Text("|").font(DesignFont.mono(DesignFont.eyebrow)).foregroundStyle(DesignPalette.hair).accessibilityHidden(true)
    }

    private var tape: some View {
        let range = range
        let biggestTake = takes.filter(\.hasTranscript).max { $0.words < $1.words }
        return GeometryReader { proxy in
            let width = proxy.size.width, height = proxy.size.height
            let slots = TapeSlots.merge(takes, range: range, width: Double(width))
            let maxWords = max(1, slots.map(\.words).max() ?? 1)
            let biggest = slots.indices.filter { slots[$0].words > 0 }.max { slots[$0].words < slots[$1].words }
            let highlighted = hovered.flatMap { $0 < slots.count ? $0 : nil } ?? biggest
            ZStack(alignment: .topLeading) {
                ForEach(range.ticks.dropFirst(), id: \.self) { hour in
                    Rectangle().fill(DesignPalette.hair2).frame(width: 1, height: height)
                        .offset(x: width * range.fraction(hour * 3_600))
                }
                Rectangle().fill(DesignPalette.hair).frame(width: width, height: 1).offset(y: height - 11)
                ForEach(slots.indices, id: \.self) { index in
                    needle(slots[index], maxWords: maxWords, highlighted: index == highlighted, width: width, height: height)
                }
                let nowX = width * range.fraction(nowSeconds)
                Rectangle().fill(DesignPalette.ink).frame(width: 1.5, height: height - 12).offset(x: nowX - 0.75, y: 6)
                Text("NOW").font(DesignFont.mono(DesignFont.axis)).tracking(0.7).foregroundStyle(DesignPalette.ink)
                    .fixedSize().offset(x: nowX + 6, y: 4)
                ForEach(range.ticks, id: \.self) { hour in
                    axis(TapeRange.label(hour, edge: hour == range.start)).offset(x: width * range.fraction(hour * 3_600) + (hour == range.start ? 6 : 5), y: height - 10)
                }
                axis(TapeRange.label(range.end, edge: true)).offset(x: width - 6 - 24, y: height - 10)
                    .frame(width: 24, alignment: .trailing)
            }
            .frame(width: width, height: height, alignment: .topLeading)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let point):
                    let nearest = slots.indices.min { abs(slots[$0].x - point.x) < abs(slots[$1].x - point.x) }
                    hovered = nearest.flatMap { abs(slots[$0].x - point.x) <= TapeSlots.minimumSpacing ? $0 : nil }
                case .ended:
                    hovered = nil
                }
            }
        }
        .frame(height: 72)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.bg))
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(DesignPalette.hair2, lineWidth: 1))
        .padding(.top, biggestTake == nil ? 0 : 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel(biggestTake))
    }

    private func axis(_ text: String) -> some View {
        Text(text).font(DesignFont.mono(DesignFont.axis)).foregroundStyle(DesignPalette.ink3).fixedSize()
    }

    private func needle(_ slot: TapeSlot, maxWords: Int, highlighted: Bool, width: CGFloat, height: CGFloat) -> some View {
        let tall = CGFloat(TapeSlots.height(words: slot.words, maxWords: maxWords))
        let wide: CGFloat = slot.isAllHollow ? 4 : 2.5
        let pad: CGFloat = highlighted ? 3 : 0
        return ZStack {
            if slot.isAllHollow {
                UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5).fill(DesignPalette.surface)
                    .overlay(UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5).strokeBorder(DesignPalette.accent, lineWidth: 1))
            } else {
                UnevenRoundedRectangle(topLeadingRadius: 1.5, topTrailingRadius: 1.5).fill(DesignPalette.accent)
            }
        }
        .frame(width: wide, height: tall)
        .overlay(alignment: .top) {
            if slot.hasHollowCap {
                Circle().fill(DesignPalette.surface).overlay(Circle().strokeBorder(DesignPalette.accent, lineWidth: 1))
                    .frame(width: 5, height: 5).offset(y: -6)
            }
        }
        .padding(pad)
        .overlay(highlighted ? RoundedRectangle(cornerRadius: 3).strokeBorder(DesignPalette.accent, lineWidth: 1) : nil)
        .overlay(alignment: callOutAlignment(x: slot.x, width: width)) {
            if highlighted { callOut(slot).fixedSize().offset(y: -28) }
        }
        .offset(x: slot.x - wide / 2 - pad, y: height - 11 - tall - pad)
        .accessibilityHidden(true)
    }

    private func callOutAlignment(x: Double, width: CGFloat) -> Alignment {
        x < width * 0.22 ? .topLeading : (x > width * 0.78 ? .topTrailing : .top)
    }

    private func callOut(_ slot: TapeSlot) -> some View {
        Group {
            if let take = slot.take {
                let parts = [StatsFormat.clock(seconds: take.secondsIntoDay), take.appName].compactMap { $0 }.joined(separator: " · ")
                let tail = StatsFormat.speaking(ms: take.durationMs).map { " · \($0)" } ?? ""
                Text("\(parts) · ") + Text("\(StatsFormat.number(take.words))").fontWeight(.semibold) + Text(" words\(tail)")
            } else {
                Text(slot.summary)
            }
        }
        .font(DesignFont.sans(11)).foregroundStyle(DesignPalette.bg)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(RoundedRectangle(cornerRadius: 6).fill(DesignPalette.ink))
    }

    private func accessibilityLabel(_ biggest: TodayTake?) -> String {
        guard let first = takes.first, let last = takes.last else { return "No takes yet today" }
        var text = "\(takes.count) \(takes.count == 1 ? "take" : "takes") today between \(StatsFormat.clock(seconds: first.secondsIntoDay)) and \(StatsFormat.clock(seconds: last.secondsIntoDay))"
        if let biggest {
            text += "; the biggest at \(StatsFormat.clock(seconds: biggest.secondsIntoDay))" + (biggest.appName.map { " in \($0)" } ?? "") + ", \(biggest.words) words"
        }
        let hollow = takes.filter { !$0.hasTranscript }.count
        if hollow > 0 { text += "; \(hollow) with audio saved and no transcript" }
        return text
    }
}

// MARK: Speaking speed

struct StatsSpeedCard: View {
    let report: StatsReport
    static let segments = 25
    static let top = 250.0

    var body: some View {
        let average = StatsFormat.meterSegment(report.averageWPM)
        let peak = StatsFormat.meterSegment(report.bestWPM)
        let typist = StatsFormat.meterSegment(report.typingWPM)
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Speaking speed").designEyebrow()
                HStack(alignment: .center, spacing: 16) {
                    HStack(alignment: .firstTextBaseline, spacing: 5) {
                        Text(report.averageWPM.map { String(Int($0.rounded())) } ?? "None")
                            .font(DesignFont.sans(34, .semibold)).foregroundStyle(DesignPalette.ink)
                        if report.averageWPM != nil { monoLine("WPM") }
                    }
                    .fixedSize()
                    VStack(spacing: 4) {
                        HStack(spacing: 2) {
                            ForEach(0..<Self.segments, id: \.self) { index in
                                RoundedRectangle(cornerRadius: 2).fill(fill(index, average: average, peak: peak))
                                    .overlay(index == typist ? RoundedRectangle(cornerRadius: 2).strokeBorder(DesignPalette.ink, lineWidth: 1.5) : nil)
                            }
                        }
                        .frame(height: 18)
                        HStack {
                            Text("0"); Spacer(); Text("\(Int(Self.top))")
                        }
                        .font(DesignFont.mono(DesignFont.axis)).tracking(0.5).foregroundStyle(DesignPalette.ink3)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(meterLabel)
                }
                HStack(spacing: 14) {
                    key(DesignPalette.accent, "average", report.averageWPM.map { String(Int($0.rounded())) } ?? "none")
                    key(DesignPalette.ink, "peak", report.bestWPM.map { String(Int($0.rounded())) } ?? "none")
                    key(DesignPalette.accent, "a typist", String(Int(report.typingWPM)), outlined: true)
                }
                if let caption {
                    Text(caption).font(DesignFont.sans(DesignFont.caption)).foregroundStyle(DesignPalette.ink2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .help("Words over speaking time, from takes of at least \(StatsEngine.minWPMWords) words and \(StatsEngine.minWPMDurationMs / 1_000) seconds.")
    }

    private var caption: String? { StatsFormat.typistRatio(wpm: report.averageWPM, typingWPM: report.typingWPM) }

    private func fill(_ index: Int, average: Int?, peak: Int?) -> Color {
        if index == peak { return DesignPalette.ink }
        if let average, index <= average { return DesignPalette.accent }
        return DesignPalette.c0
    }

    private func key(_ color: Color, _ label: String, _ value: String, outlined: Bool = false) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 10)
                .overlay(outlined ? RoundedRectangle(cornerRadius: 2).strokeBorder(DesignPalette.ink, lineWidth: 1.5) : nil)
            (Text(label).foregroundStyle(DesignPalette.ink2) + Text(" \(value)").foregroundStyle(DesignPalette.ink))
                .font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8).textCase(.uppercase)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(label) \(value)")
    }

    private var meterLabel: String {
        "A meter from 0 to \(Int(Self.top)) words per minute: lit to the average of \(report.averageWPM.map { String(Int($0.rounded())) } ?? "none"), a dark segment at the best of \(report.bestWPM.map { String(Int($0.rounded())) } ?? "none"), an outlined segment at a typist's \(Int(report.typingWPM))"
    }
}

// MARK: Streak

struct StatsStreakCard: View {
    let daily: [DailyWords]
    let current: Int
    let longest: Int

    var body: some View {
        let lit = StatsTimeline.streakLit(daily: daily, currentStreak: current)
        StatsCard {
            VStack(alignment: .leading, spacing: 12) {
                Text("Streak · last \(StatsSnapshot.dailyWindowDays) days").designEyebrow()
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    HStack(alignment: .center, spacing: 6) {
                        FlameShape().fill(DesignPalette.orange).frame(width: 20, height: 20).accessibilityHidden(true)
                        Text("\(current)").font(DesignFont.sans(34, .semibold)).foregroundStyle(DesignPalette.ink)
                        monoLine("\(current == 1 ? "DAY" : "DAYS")").padding(.leading, 2)
                    }
                    Spacer(minLength: 0)
                    (Text("LONGEST ").foregroundStyle(DesignPalette.ink3) + Text("\(longest)").foregroundStyle(DesignPalette.ink))
                        .font(DesignFont.mono(DesignFont.eyebrow)).tracking(0.8)
                }
                VStack(spacing: 5) {
                    HStack(spacing: 2) {
                        ForEach(daily.indices, id: \.self) { index in
                            Circle().fill(dotColor(index, lit: lit))
                                .aspectRatio(1, contentMode: .fit)
                                .frame(minWidth: 0)
                                .overlay(index == daily.count - 1 && daily[index].words == 0
                                         ? Circle().strokeBorder(DesignPalette.accent, lineWidth: 1.5).background(Circle().fill(DesignPalette.surface)) : nil)
                        }
                    }
                    .padding(.horizontal, 2)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(daily.count) dots, one per day; the last \(lit.filter { $0 }.count) are lit" + (daily.last?.words == 0 ? "; today is an outline until you dictate" : ""))
                    HStack {
                        Text(daily.first.map { StatsFormat.shortDay($0.day).uppercased() } ?? "")
                        Spacer()
                        Text("TODAY").foregroundStyle(DesignPalette.ink)
                    }
                    .font(DesignFont.mono(DesignFont.axis)).tracking(0.5).foregroundStyle(DesignPalette.ink3).accessibilityHidden(true)
                }
            }
        }
        .help("A day counts with one take, and today carries until midnight.")
    }

    private func dotColor(_ index: Int, lit: [Bool]) -> Color {
        if lit[index] { return DesignPalette.accent }
        return daily[index].words > 0 ? DesignPalette.c2 : DesignPalette.c0
    }
}

/// The streak flame, from the handoff's 16 pt glyph.
struct FlameShape: Shape {
    func path(in rect: CGRect) -> Path {
        let s = rect.width / 16
        func p(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: rect.minX + x * s, y: rect.minY + y * s) }
        var path = Path()
        path.move(to: p(8, 1.2))
        path.addCurve(to: p(11.6, 8.5), control1: p(8.4, 3.8), control2: p(11.6, 5.0))
        path.addCurve(to: p(8, 12.1), control1: p(11.6, 10.488), control2: p(9.988, 12.1))
        path.addCurve(to: p(4.4, 8.5), control1: p(6.012, 12.1), control2: p(4.4, 10.488))
        path.addCurve(to: p(5.8, 5.5), control1: p(4.4, 7.1), control2: p(5.1, 6.1))
        path.addCurve(to: p(7.3, 7.1), control1: p(6.0, 6.5), control2: p(6.5, 7.1))
        path.addCurve(to: p(8, 1.2), control1: p(7.4, 5.6), control2: p(6.9, 3.5))
        path.closeSubpath()
        return path
    }
}

// MARK: Your day

struct StatsDayCard: View {
    let hourly: [Int]

    var body: some View {
        let peak = StatsTimeline.peakHour(hourly)
        let total = hourly.reduce(0, +)
        let maxWords = max(1, hourly.max() ?? 1)
        StatsCard {
            VStack(alignment: .leading, spacing: 14) {
                text(peak: peak, total: total)
                chart(peak: peak, maxWords: maxWords)
            }
        }
    }

    private func text(peak: Int?, total: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Your day · last \(StatsTimeline.hourWindowDays) days").designEyebrow()
            Text(peak.map { "A \(StatsFormat.hourName($0)) talker." } ?? "No pattern yet.")
                .font(DesignFont.serif(30)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
            if let detail = detail(peak: peak, total: total) {
                Text(detail).font(DesignFont.sans(DesignFont.detail)).foregroundStyle(DesignPalette.ink2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func detail(peak: Int?, total: Int) -> String? {
        guard let peak, total > 0 else { return nil }
        return "\(Int((Double(hourly[peak]) / Double(total) * 100).rounded()))% of your words."
    }

    /// Stretches to whatever height the card has left, so it matches the card beside it.
    private func chart(peak: Int?, maxWords: Int) -> some View {
        VStack(spacing: 4) {
            GeometryReader { proxy in
                HStack(alignment: .bottom, spacing: 0) {
                    ForEach(0..<StatsTimeline.hoursPerDay, id: \.self) { hour in
                        let words = hour < hourly.count ? hourly[hour] : 0
                        Group {
                            if words == 0 {
                                Rectangle().fill(DesignPalette.c0).frame(height: 2)
                            } else {
                                UnevenRoundedRectangle(topLeadingRadius: 2, topTrailingRadius: 2)
                                    .fill(hour == peak ? DesignPalette.accent : DesignPalette.c2)
                                    .frame(height: max(3, proxy.size.height * CGFloat(words) / CGFloat(maxWords)))
                            }
                        }
                        .frame(width: 5)
                        if hour < StatsTimeline.hoursPerDay - 1 { Spacer(minLength: 0) }
                    }
                }
                .frame(width: proxy.size.width, height: proxy.size.height, alignment: .bottom)
            }
            .frame(minHeight: 64, maxHeight: .infinity)
            HStack { Text("12 AM"); Spacer(); Text("NOON"); Spacer(); Text("11 PM") }
                .font(DesignFont.mono(DesignFont.axis)).tracking(0.5).foregroundStyle(DesignPalette.ink3)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(peak.map { "Words by hour of day over the last \(StatsTimeline.hourWindowDays) days, peaking at \(StatsFormat.hourName($0))" }
                            ?? "Words by hour of day over the last \(StatsTimeline.hourWindowDays) days, no takes")
    }
}

// MARK: High scores

struct StatsHighScoresCard: View {
    let records: ArcadeRecords
    let today: String

    var body: some View {
        StatsCard(padding: EdgeInsets(top: 14, leading: 20, bottom: 12, trailing: 20)) {
            VStack(alignment: .leading, spacing: 4) {
                Text("High scores").designEyebrow().padding(.bottom, 4)
                score("01", "Fastest speaking", records.wpm.map { "\(Int($0.value.rounded())) WPM" }, records.wpm?.setOn)
                score("02", "Biggest day", records.biggestDay.map { StatsFormat.number($0.value) }, records.biggestDay?.setOn)
                score("03", "Longest streak", records.longestStreak.map { StatsFormat.days($0.value).uppercased() }, records.longestStreak?.setOn)
                score("04", "Longest take", records.longestDictation.map { StatsFormat.number($0.value.words) }, records.longestDictation?.setOn,
                      extra: StatsFormat.speaking(ms: records.longestDictation?.value.durationMs))
            }
        }
    }

    private func score(_ number: String, _ title: String, _ value: String?, _ day: String?, extra: String? = nil) -> some View {
        let date = day.map { StatsFormat.recordDate($0, today: today) }
        let detail = [date, extra].compactMap { $0 }.joined(separator: " · ")
        return VStack(spacing: 0) {
            DesignHairline()
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text(number).font(DesignFont.mono(DesignFont.eyebrow)).foregroundStyle(DesignPalette.ink3).frame(width: 18, alignment: .leading)
                Text(title).font(DesignFont.sans(12.5)).foregroundStyle(DesignPalette.ink).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(value ?? "None yet").font(DesignFont.mono(13).weight(.medium))
                        .foregroundStyle(value == nil ? DesignPalette.ink3 : DesignPalette.ink)
                    if !detail.isEmpty { Text(detail).font(DesignFont.sans(11)).foregroundStyle(DesignPalette.ink3) }
                }
                .multilineTextAlignment(.trailing).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.vertical, 5)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value ?? "none yet")" + (detail.isEmpty ? "" : ", \(detail)"))
    }
}
