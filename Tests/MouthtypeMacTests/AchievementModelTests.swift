import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func hit() { lock.lock(); value += 1; lock.unlock() }
}

@MainActor @Suite struct AchievementModelTests {
    private let zone = TimeZone(secondsFromGMT: 0)!
    private let now = Date(timeIntervalSince1970: 1_792_300_000)

    private func isolated() -> (UserDefaults, () -> Void) {
        let name = "mouthtype-achievement-model-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    private func snapshot(words: Int = 1_200, takes: Int = 4) -> StatsSnapshot {
        StatsSnapshot(
            report: StatsReport(
                wordsToday: 0, wordsThisWeek: 0, wordsAllTime: words, dictationCount: takes, averageWPM: nil, bestWPM: nil,
                currentStreakDays: 0, longestStreakDays: 1, biggestDay: nil, longestDictation: nil, minutesSaved: 0, typingWPM: 40,
                firstDay: "2026-10-01"),
            records: ArcadeRecords(), daily: [])
    }

    private func refresh(_ model: AchievementModel, _ snapshot: StatsSnapshot, counter: CallCounter, revision: Int = 0) async {
        await model.refresh(snapshot: snapshot, now: now, timeZone: zone, revision: revision) { _ in
            counter.hit()
            return AchievementExtras(days: [.init(day: "2026-10-01", takes: 4, words: 1_200)])
        }
    }

    @Test func refreshEarnsRecordsAndStaysIdempotent() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(), counter: counter)
        #expect(model.entries.count == AchievementCatalog.all.count)
        #expect(model.entries.first { $0.id == "four_figures" }?.state == .earned(day: "2026-10-01"))
        // The first run is the backfill: nothing is new.
        #expect(model.entries.allSatisfy { !$0.isNew })
        let stored = AchievementStore(defaults: defaults).earned
        await refresh(model, snapshot(), counter: counter)
        #expect(AchievementStore(defaults: defaults).earned == stored)
        // Same take count, same counters: the second read is skipped.
        #expect(counter.count == 1)
    }

    @Test func extrasAreReReadWhenTheTakeCountOrACounterChanges() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(takes: 4), counter: counter)
        await refresh(model, snapshot(takes: 4), counter: counter)
        #expect(counter.count == 1)
        await refresh(model, snapshot(takes: 5), counter: counter)
        #expect(counter.count == 2)
        AchievementStore(defaults: defaults).increment(.voiceEdits, day: "2026-10-01")
        await refresh(model, snapshot(takes: 5), counter: counter)
        #expect(counter.count == 3)
        AchievementStore(defaults: defaults).increment(.transforms, day: "2026-10-01")
        await refresh(model, snapshot(takes: 5), counter: counter)
        #expect(counter.count == 4)
        // Switching off and on drops the cache.
        model.setEnabled(false)
        model.setEnabled(true)
        await refresh(model, snapshot(takes: 5), counter: counter)
        #expect(counter.count == 5)
    }

    @Test func aStoreWriteWithTheSameTakeCountInvalidatesTheCache() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(), counter: counter, revision: 3)
        await refresh(model, snapshot(), counter: counter, revision: 3)
        #expect(counter.count == 1)
        await refresh(model, snapshot(), counter: counter, revision: 4)
        #expect(counter.count == 2)
    }

    @Test func aCachedReadStillPicksUpTheCurrentCounters() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(), counter: counter)
        let store = AchievementStore(defaults: defaults)
        #expect(store.counters.voiceEdits == 0)
        store.increment(.voiceEdits, day: "2026-10-01")
        await refresh(model, snapshot(), counter: counter)
        #expect(model.entries.first { $0.id == "four_figures" }?.state == .earned(day: "2026-10-01"))
    }

    @Test func newStaysOnACollapsedShelfUntilSeenExpanded() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(words: 0, takes: 0), counter: counter)
        await refresh(model, snapshot(), counter: counter)
        #expect(model.hasNew)
        model.setShelfHidden(true)
        model.shelfSeen()
        #expect(model.hasNew)
        #expect(!AchievementStore(defaults: defaults).seen.contains("four_figures"))
        model.setShelfHidden(false)
        model.shelfSeen()
        #expect(!model.hasNew)
        #expect(AchievementStore(defaults: defaults).seen.contains("four_figures"))
    }

    @Test func switchedOffMeansNoWorkAndNoShelf() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(), counter: counter)
        #expect(!model.entries.isEmpty)
        model.setEnabled(false)
        #expect(model.entries.isEmpty && !model.isEnabled)
        await refresh(model, snapshot(), counter: counter)
        #expect(counter.count == 1 && model.entries.isEmpty)
        // Nothing earned is taken back by switching off and on.
        model.setEnabled(true)
        await refresh(model, snapshot(words: 0, takes: 0), counter: counter)
        #expect(model.entries.first { $0.id == "four_figures" }?.state == .earned(day: "2026-10-01"))
        #expect(AchievementModel(defaults: defaults).isEnabled)
    }

    @Test func aFreshModelOnDefaultsThatSaidOffStaysOff() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        AchievementStore(defaults: defaults).setEnabled(false)
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(), counter: counter)
        #expect(!model.isEnabled && counter.count == 0 && model.entries.isEmpty)
    }

    @Test func theHideChoicePersists() {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        #expect(!model.isShelfHidden)
        model.setShelfHidden(true)
        #expect(AchievementModel(defaults: defaults).isShelfHidden)
    }

    @Test func earnsAfterTheBackfillAreNewUntilTheShelfLeavesTheScreen() async {
        let (defaults, cleanup) = isolated()
        defer { cleanup() }
        let model = AchievementModel(defaults: defaults)
        let counter = CallCounter()
        await refresh(model, snapshot(words: 0, takes: 0), counter: counter)
        await refresh(model, snapshot(), counter: counter)
        #expect(model.entries.first { $0.id == "four_figures" }?.isNew == true)
        model.shelfSeen()
        #expect(model.entries.allSatisfy { !$0.isNew })
        #expect(AchievementStore(defaults: defaults).seen.contains("four_figures"))
    }

    // MARK: Tiles

    @Test func tileLabelsGiveNameTierCopyAndDateOrProgress() {
        let earned = AchievementShelfEntry(
            id: "four_figures", group: .volume, tier: .bronze, name: "Four Figures", copy: "1,000 words and your keyboard didn't feel a thing.",
            state: .earned(day: "2026-10-12"), isApproximate: false, isNew: false)
        #expect(
            AchievementTile.accessibilityLabel(earned, today: "2026-11-02")
                == "Four Figures, bronze, earned oct 12. 1,000 words and your keyboard didn't feel a thing.")
        var before = earned
        before.isApproximate = true
        before.state = .earned(day: nil)
        before.isNew = true
        #expect(AchievementTile.accessibilityLabel(before, today: "2026-11-02").hasPrefix("Four Figures, bronze, earned before trophies, new."))
        let locked = AchievementShelfEntry(
            id: "five_figures", group: .volume, tier: .silver, name: "Five Figures", copy: "x",
            state: .locked(AchievementProgress(current: 7_420, target: 10_000, line: "7,420 of 10,000 words")), isApproximate: false, isNew: false)
        #expect(AchievementTile.accessibilityLabel(locked, today: "2026-11-02") == "Five Figures, silver, locked. 7,420 of 10,000 words")
        var hidden = locked
        hidden.state = .hidden
        let label = AchievementTile.accessibilityLabel(hidden, today: "2026-11-02")
        #expect(label == "Hidden trophy, locked. Keep talking." && !label.contains("Five"))
    }

    @Test func tilesFlowIntoAsManyColumnsAsFit() {
        #expect(AchievementFlow.columns(for: 700) == 3)
        #expect(AchievementFlow.columns(for: 450) == 2)
        #expect(AchievementFlow.columns(for: 300) == 1)
        #expect(AchievementFlow.columns(for: 0) == 1)
    }
}

@Suite struct TrophyArtTests {
    @Test func everyCatalogEntryHasAWellFormedSprite() {
        for definition in AchievementCatalog.all {
            let rows = AchievementSprites.rows(for: definition.id)
            #expect(rows?.count == 12, "\(definition.id)")
            for row in rows ?? [] {
                #expect(row.count == 12, "\(definition.id) \(row)")
                #expect(row.allSatisfy { $0 == "." || AchievementSprites.palette[$0] != nil }, "\(definition.id) \(row)")
            }
        }
        #expect(AchievementSprites.rows(for: AchievementSprites.hiddenID)?.count == 12)
    }

    @Test func shortRowsAreCentredAndPadded() {
        let rows = AchievementSprites.normalized(["kk", "k"])
        #expect(rows.count == 12 && rows[0] == ".....kk....." && rows[1] == ".....k......")
        #expect(rows.allSatisfy { $0.count == 12 })
    }

    @Test func cupIsTwentyFourByTwentyThreeAndTheTierColoursTheBody() throws {
        #expect(TrophyArt.cup.count == 23 && TrophyArt.cup.allSatisfy { $0.count == 24 })
        let bronze = TrophyArt.canvas(spriteID: "four_figures", face: .earned(.bronze), dark: false)
        let gold = TrophyArt.canvas(spriteID: "four_figures", face: .earned(.gold), dark: false)
        #expect(bronze.width == 24 && bronze.height == 23 && bronze.image != nil)
        // Outline, body and the cream face.
        #expect(bronze.pixel(4, 0) == PixelColor(hex: 0x1D1D1F))
        #expect(bronze.pixel(10, 17) == PixelColor(hex: 0xB8733A))
        #expect(gold.pixel(10, 17) == PixelColor(hex: 0xBB8C1A))
        #expect(bronze.pixel(6, 2) == PixelColor(hex: 0xF1EEE2))
        #expect(TrophyArt.canvas(spriteID: "four_figures", face: .earned(.bronze), dark: true).pixel(10, 17) == PixelColor(hex: 0xD98C4F))
        // Corners of the canvas stay clear.
        #expect(bronze.pixel(0, 0) == nil && bronze.pixel(23, 22) == nil)
    }

    @Test func lockedAndHiddenAreDimAndDoNotShowTheTier() {
        let locked = TrophyArt.canvas(spriteID: "five_figures", face: .locked, dark: false)
        let hidden = TrophyArt.canvas(spriteID: "five_figures", face: .hidden, dark: false)
        #expect(locked.pixel(10, 17) == PixelColor(hex: 0xD9D9DE))
        #expect(hidden.pixel(10, 17) == PixelColor(hex: 0xD9D9DE))
        #expect(locked.pixels != hidden.pixels)
        #expect(locked.pixels != TrophyArt.canvas(spriteID: "five_figures", face: .earned(.silver), dark: false).pixels)
    }

    @Test func pixelBytesArePremultipliedRGBA() {
        var canvas = PixelCanvas(width: 2, height: 1)
        canvas.paint(0, 0, PixelColor(hex: 0xFFFFFF, alpha: 0.5))
        #expect(canvas.bytes == [128, 128, 128, 128, 0, 0, 0, 0])
        canvas.paint(0, 0, PixelColor(hex: 0x000000, alpha: 1))
        #expect(canvas.bytes[0] == 0 && canvas.bytes[3] == 255)
    }
}
