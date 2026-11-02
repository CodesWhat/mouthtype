import Foundation

/// The set: achievements worked out from data the app already keeps, plus the few that count a local action. Pure, so each entry is tested on
/// fixtures. Copy is the approved deadpan wording from the design doc.
public enum AchievementCatalog {
    public static let all: [AchievementDefinition] = firstSteps + volume + streaks + speed + craft + hidden

    public static func definition(id: String) -> AchievementDefinition? { all.first { $0.id == id } }

    // MARK: Entries

    private static let firstSteps: [AchievementDefinition] = [
        entry("first_words", .firstSteps, .bronze, "First Words", "Congrats, your mouth is now a keyboard.") { input in
            let takes = input.report.dictationCount
            return reading(Double(takes), 1, "Say your first words", day: input.report.firstDay)
        },
        entry("hands_free", .firstSteps, .bronze, "Hands Free", "Hands off the keys. Mouth on the job.") { input in
            reading(Double(input.extras.handsFreeCount), 1, "Start a take hands free", day: input.extras.handsFreeFirstDay)
        },
        entry("many_apps", .firstSteps, .bronze, "Many Apps, One Voice", "One mouth, three apps. Busy mouth.") { input in
            reading(Double(input.extras.distinctApps), 3, "\(min(input.extras.distinctApps, 3)) of 3 apps", day: input.extras.thirdAppDay)
        },
    ]

    private static let volume: [AchievementDefinition] = [
        wordsEntry("four_figures", .bronze, "Four Figures", "1,000 words and your keyboard didn't feel a thing.", 1_000),
        wordsEntry("five_figures", .silver, "Five Figures", "10,000 words. Your keyboard filed for early retirement.", 10_000),
        wordsEntry("six_figures", .gold, "Six Figures", "100,000 words. Your keyboard is gathering dust.", 100_000),
        takesEntry("hundred_takes", .bronze, "Hundred Takes", "100 takes. That's a lot of \"testing, testing\".", 100),
        takesEntry("thousand_takes", .silver, "Thousand Takes", "1,000 takes. Your mic has heard it all.", 1_000),
        entry("monologue", .volume, .silver, "Monologue", "300 words in one take. Someone get this person a podium.") { input in
            let words = input.report.longestDictation?.words ?? 0
            return reading(
                Double(words), 300, "Longest take is \(number(words)) of 300 words", day: input.records.longestDictation?.setOn)
        },
    ]

    private static let streaks: [AchievementDefinition] = [
        streakEntry("three_row", .bronze, "Three in a Row", "Three days running. A habit is hatching.", 3),
        streakEntry("no_days_off", .silver, "No Days Off", "Seven days straight. Even your mouth works weekends.", 7),
        streakEntry("month", .gold, "Month of Mouths", "30 days running. The flame is yours, don't let it out.", 30),
        streakEntry("century", .gold, "Century", "100 days in a row. Longer than most New Year's resolutions.", 100),
    ]

    private static let speed: [AchievementDefinition] = [
        wpmEntry("fast_talker", .bronze, "Fast Talker", "150 words a minute. A typist is still on sentence one.", 150),
        wpmEntry("auctioneer", .silver, "Auctioneer", "200 words a minute. Going once, going twice, sold.", 200),
        entry("triple_speed", .speed, .silver, "Triple Speed", "You talk three times faster than you type. Typing is jealous.") { input in
            guard let average = input.report.averageWPM, input.report.typingWPM > 0 else {
                return reading(0, 3, "Average speed needs a few longer takes", day: nil)
            }
            let ratio = average / input.report.typingWPM
            return reading(ratio, 3, "Average speed is \(String(format: "%.1f", ratio))x your typing", day: nil)
        },
        savedEntry("hour_back", .bronze, "An Hour Back", "One hour saved. Go do something with it.", 60),
        savedEntry("workday_back", .gold, "A Workday Back", "Eight hours saved. Tell your boss you finished early.", 480),
    ]

    private static let craft: [AchievementDefinition] = [
        entry("honest_baseline", .craft, .bronze, "Honest Baseline", "You timed your typing. Now the comparison is fair.") { input in
            reading(input.extras.calibrated ? 1 : 0, 1, "Take the typing test at the bottom of this page", day: nil)
        },
        entry("second_draft", .craft, .bronze, "Second Draft", "You said what to fix and it got fixed. No cursor involved.") { input in
            let counters = input.extras.counters
            return reading(
                Double(counters.voiceEdits), 1, "Edit a selection by voice. Counted from install.",
                day: counters.day(.voiceEdits, reaching: 1))
        },
        entry("editor", .craft, .silver, "Editor", "25 voice edits. Your mouse is getting lonely.") { input in
            let counters = input.extras.counters
            return reading(
                Double(counters.voiceEdits), 25, "\(min(counters.voiceEdits, 25)) of 25 voice edits, counted from install",
                day: counters.day(.voiceEdits, reaching: 25))
        },
        entry("reworded", .craft, .bronze, "Reworded", "Same idea, new wording. You never touched a key.") { input in
            let counters = input.extras.counters
            return reading(
                Double(counters.transforms), 1, "Run a transform on a selection. Counted from install.",
                day: counters.day(.transforms, reaching: 1))
        },
        entry("proper_noun", .craft, .bronze, "Proper Noun", "Saved a spelling. It'll get that name right from now on.") { input in
            reading(Double(input.extras.rememberedCount), 1, "No spellings saved yet", day: input.extras.firstRememberedDay)
        },
        entry("shortcut", .craft, .silver, "Shortcut Taken", "10 snippets expanded. A few words, a whole paragraph.") { input in
            reading(
                Double(input.extras.snippetCount), 10, "\(min(input.extras.snippetCount, 10)) of 10 snippets",
                day: input.extras.snippetTenthDay)
        },
    ]

    private static let hidden: [AchievementDefinition] = [
        entry("night_owl", .hidden, .bronze, "Night Owl", "Dictating in the middle of the night. Hoo does that? You.", hidden: true) { input in
            reading(input.extras.nightOwlDay == nil ? 0 : 1, 1, "", day: input.extras.nightOwlDay)
        },
        entry("filibuster", .hidden, .silver, "Filibuster", "Five minutes in one take. Senate material.", hidden: true) { input in
            reading(Double(input.extras.longestDurationMs ?? 0), 300_000, "", day: input.extras.longestDurationDay)
        },
        entry("welcome_back", .hidden, .bronze, "Welcome Back", "A month away and you're back. We kept your seat warm.", hidden: true) { input in
            let day = returnDay(input.extras.days, gapDays: 30)
            return reading(day == nil ? 0 : 1, 1, "", day: day)
        },
    ]

    // MARK: Builders

    private static func entry(
        _ id: String, _ group: AchievementGroup, _ tier: AchievementTier, _ name: String, _ copy: String, hidden: Bool = false,
        read: @escaping @Sendable (AchievementInput) -> AchievementReading
    ) -> AchievementDefinition {
        AchievementDefinition(id: id, group: group, tier: tier, isHidden: hidden, name: name, copy: copy, read: read)
    }

    private static func reading(_ value: Double, _ target: Double, _ line: String, day: String?) -> AchievementReading {
        AchievementReading(value: value, target: target, line: line, day: day)
    }

    private static func wordsEntry(_ id: String, _ tier: AchievementTier, _ name: String, _ copy: String, _ target: Int) -> AchievementDefinition {
        entry(id, .volume, tier, name, copy) { input in
            let words = input.report.wordsAllTime
            return reading(
                Double(words), Double(target), "\(number(min(words, target))) of \(number(target)) words",
                day: crossingDay(input.extras.days, target: target) { $0.words })
        }
    }

    private static func takesEntry(_ id: String, _ tier: AchievementTier, _ name: String, _ copy: String, _ target: Int) -> AchievementDefinition {
        entry(id, .volume, tier, name, copy) { input in
            let takes = input.report.dictationCount
            return reading(
                Double(takes), Double(target), "\(number(min(takes, target))) of \(number(target)) takes",
                day: crossingDay(input.extras.days, target: target) { $0.takes })
        }
    }

    private static func streakEntry(_ id: String, _ tier: AchievementTier, _ name: String, _ copy: String, _ target: Int) -> AchievementDefinition {
        entry(id, .streaks, tier, name, copy) { input in
            let longest = input.report.longestStreakDays
            return reading(
                Double(longest), Double(target), "\(min(longest, target)) of \(target) days",
                day: streakDay(input.extras.days, length: target))
        }
    }

    private static func wpmEntry(_ id: String, _ tier: AchievementTier, _ name: String, _ copy: String, _ target: Int) -> AchievementDefinition {
        entry(id, .speed, tier, name, copy) { input in
            guard let best = input.report.bestWPM else {
                return reading(0, Double(target), "Needs a take of \(StatsEngine.minWPMWords)+ words and \(StatsEngine.minWPMDurationMs / 1_000)+ seconds", day: nil)
            }
            return reading(
                best, Double(target), "Best is \(Int(best.rounded(.down))) of \(target) WPM", day: input.records.wpm?.setOn)
        }
    }

    private static func savedEntry(_ id: String, _ tier: AchievementTier, _ name: String, _ copy: String, _ targetMinutes: Int) -> AchievementDefinition {
        entry(id, .speed, tier, name, copy) { input in
            let saved = input.report.minutesSaved
            return reading(
                saved, Double(targetMinutes), "\(hoursAndMinutes(min(saved, Double(targetMinutes)))) of \(hoursAndMinutes(Double(targetMinutes))) saved",
                day: savedDay(input.extras.days, typingWPM: input.report.typingWPM, minutes: Double(targetMinutes)))
        }
    }

    // MARK: Dates for a backfill

    /// The first day the running total of `value` reached `target`.
    static func crossingDay(_ days: [AchievementExtras.Day], target: Int, value: (AchievementExtras.Day) -> Int) -> String? {
        var total = 0
        for day in days {
            total += value(day)
            if total >= target { return day.day }
        }
        return nil
    }

    /// The day a run of consecutive local days first reached `length`.
    static func streakDay(_ days: [AchievementExtras.Day], length: Int) -> String? {
        var run = 0
        var previous: Int?
        for day in days {
            guard let number = Streaks.dayNumber(day.day) else { continue }
            run = previous.map { number == $0 + 1 } == true ? run + 1 : 1
            previous = number
            if run >= length { return day.day }
        }
        return nil
    }

    /// The first day the running minutes saved reached `minutes`, worked the way `StatsReport.minutesSaved` is.
    static func savedDay(_ days: [AchievementExtras.Day], typingWPM: Double, minutes: Double) -> String? {
        guard typingWPM > 0 else { return nil }
        var typing = 0.0, speaking = 0.0
        for day in days {
            typing += Double(day.timedWords) / typingWPM
            speaking += Double(day.timedMs) / 60_000
            if typing - speaking >= minutes { return day.day }
        }
        return nil
    }

    /// The first day that follows at least `gapDays` whole days with no words.
    static func returnDay(_ days: [AchievementExtras.Day], gapDays: Int) -> String? {
        var previous: Int?
        for day in days {
            guard let number = Streaks.dayNumber(day.day) else { continue }
            if let previous, number - previous - 1 >= gapDays { return day.day }
            previous = number
        }
        return nil
    }

    // MARK: Text

    static func number(_ value: Int) -> String { value.formatted(.number.locale(Locale(identifier: "en_US"))) }

    /// "1 h 11 min", "8 h", "45 min".
    static func hoursAndMinutes(_ minutes: Double) -> String {
        let total = Int(minutes.rounded(.down))
        let hours = total / 60, rest = total % 60
        if hours == 0 { return "\(rest) min" }
        return rest == 0 ? "\(hours) h" : "\(hours) h \(rest) min"
    }
}
