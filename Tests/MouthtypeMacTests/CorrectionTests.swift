import AppKit
import ApplicationServices
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
private final class FakeReader: CorrectionFieldReading {
    var pid: pid_t? = 100
    var focused: FocusedElement? = FocusedElement(AXUIElementCreateApplication(100))
    var secure = false
    var secureInput = false
    var running = true
    var value: String?
    var reads = 0

    func probe() -> FocusProbe { FocusProbe(pid: pid, element: focused, isSecure: secure) }
    func value(of element: FocusedElement) -> String? {
        reads += 1
        return value
    }
    func isRunning(pid: pid_t) -> Bool { running }
    var isSecureInputEnabled: Bool { secureInput }
}

@MainActor
private final class FakeCards: CorrectionCards {
    var isFree = true
    var presented: [DeliveryCard] = []
    var onOfferAccepted: (@MainActor (DeliveryCard) -> Bool)?
    var onOfferResolved: (@MainActor (DeliveryCard, OfferResolution) -> Void)?
    func present(_ card: DeliveryCard) {
        presented.append(card)
        isFree = false
    }
}

private final class FakeStore: CorrectionStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var rows: [(Int64, String, String, Bool?)] = []
    func offered(dictationID: String, kind: CorrectionKind, heard: String, corrected: String) async -> Int64? {
        lock.withLock {
            let id = Int64(rows.count + 1)
            rows.append((id, heard, corrected, nil))
            return id
        }
    }
    func resolved(_ id: Int64, accepted: Bool?) async {
        lock.withLock { rows[Int(id) - 1].3 = accepted }
    }
    var accepted: [Bool?] { lock.withLock { rows.map(\.3) } }
    var count: Int { lock.withLock { rows.count } }
}

/// A clock whose time only moves when told and whose sleeps never wake, so a test drives `tick()` by hand.
private final class StillClock: DictationClock, @unchecked Sendable {
    private let lock = NSLock()
    private var date = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { lock.withLock { date = date.addingTimeInterval(seconds) } }
    func nowNanos() -> UInt64 { 0 }
    func milliseconds(from start: UInt64, to end: UInt64) -> Int { 0 }
    func now() -> Date { lock.withLock { date } }
    func date(atNanos nanos: UInt64) -> Date { now() }
    func sleep(forSeconds seconds: TimeInterval) async throws { try await Task.sleep(for: .seconds(3600)) }
}

@MainActor
private final class Input {
    var count: UInt64? = 0
}

@MainActor
private struct Rig {
    let reader = FakeReader()
    let cards = FakeCards()
    let store = FakeStore()
    let clock = StillClock()
    let input = Input()
    let directory: URL
    let dictionary: FileVocabulary
    let ledger: CorrectionLedger
    let watcher: CorrectionWatcher
    let state = State()
    var traces: [String] { state.traces }

    final class State {
        var traces: [String] = []
        var enabled = true
        var canOffer = true
        var notices: [String] = []
    }

    static let sentence = "Hove said the new build is ready for review today"
    static let fixed = "Hov said the new build is ready for review today"

    init(rules: String? = nil, enabled: Bool = true) {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-corrections-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("dictionary.json")
        if let rules { try? rules.write(to: url, atomically: true, encoding: .utf8) }
        dictionary = FileVocabulary(url: url)
        ledger = CorrectionLedger(url: directory.appendingPathComponent("corrections.json"), now: { [clock] in clock.now() })
        state.enabled = enabled
        let state = state, input = input
        watcher = CorrectionWatcher(
            reader: reader, dictionary: dictionary, ledger: ledger, store: store, cards: cards, clock: clock,
            input: { input.count }, isEnabled: { state.enabled }, canOffer: { state.canOffer }
        )
        watcher.onTrace = { state.traces.append($0) }
        watcher.onNotice = { state.notices.append($0.headline) }
        reader.value = Self.sentence
    }

    var target: FocusSnapshot { FocusSnapshot(pid: 100, bundleID: "com.example.app", element: reader.focused) }

    func paste(_ text: String = Rig.sentence) {
        watcher.pasted(text, dictationID: "d1", target: target)
    }

    /// Moves time on `seconds` and polls once.
    func step(_ seconds: TimeInterval) {
        clock.advance(seconds)
        watcher.tick()
    }

    func settle(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<200 where !condition() { try? await Task.sleep(for: .milliseconds(10)) }
    }

    /// The edit is made and the watch runs until the offer shows.
    func editAndWait() async {
        reader.value = Self.fixed
        step(0.5)
        step(2.1)
        await settle { !cards.presented.isEmpty }
    }
}

@MainActor
@Suite struct CorrectionWatcherTests {
    @Test func aWatchStartsOnlyWhenTheFieldIsReadableAndPlain() {
        let rig = Rig()
        rig.paste()
        #expect(rig.watcher.isWatching)

        rig.reader.value = nil
        rig.paste()
        #expect(!rig.watcher.isWatching && rig.traces.last == "not watching: field value unreadable")

        rig.reader.value = Rig.sentence
        rig.watcher.pasted(Rig.sentence, dictationID: "d", target: FocusSnapshot(pid: 100, isSecure: true, element: rig.reader.focused))
        #expect(!rig.watcher.isWatching)
        rig.watcher.pasted(Rig.sentence, dictationID: "d", target: FocusSnapshot(pid: 100, element: nil))
        #expect(!rig.watcher.isWatching)
        rig.watcher.pasted(Rig.sentence, dictationID: "d", target: nil)
        #expect(!rig.watcher.isWatching)
    }

    @Test func aFieldOverTheLearnerCapIsNeverWatchedAndStopsWhenItGrowsPastIt() {
        var rig = Rig()
        rig.reader.value = String(repeating: "a", count: CorrectionLearner.maxFieldCharacters + 2)
        rig.paste()
        #expect(!rig.watcher.isWatching && rig.traces.last == "not watching: field too large")

        rig = Rig()
        rig.paste()
        #expect(rig.watcher.isWatching)
        rig.reader.value = String(repeating: "a", count: CorrectionLearner.maxFieldCharacters + 2)
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: field too large") == true)
    }

    @Test func withTheSettingOffNothingIsReadAtAll() {
        let rig = Rig(enabled: false)
        rig.paste()
        #expect(!rig.watcher.isWatching && rig.reader.reads == 0)
    }

    @Test func turningTheSettingOffMidWatchStopsIt() {
        let rig = Rig()
        rig.paste()
        rig.step(0.5)
        rig.state.enabled = false
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: setting off") == true)
    }

    @Test func eachPollReadsTheFieldOnce() {
        let rig = Rig()
        rig.paste()
        let before = rig.reader.reads
        rig.step(0.5)
        rig.step(0.5)
        #expect(rig.reader.reads == before + 2)
    }

    @Test func anEditIsOfferedOnlyAfterTwoQuietSeconds() async {
        let rig = Rig()
        rig.paste()
        rig.reader.value = Rig.fixed
        rig.step(0.5)
        rig.step(1.4)
        rig.step(0.1)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(rig.cards.presented.isEmpty && !rig.traces.contains { $0.hasPrefix("evaluated") })
        rig.step(0.6)
        await rig.settle { !rig.cards.presented.isEmpty }
        #expect(rig.cards.presented == [.rememberSpelling(SpellingPair(heard: "Hove", corrected: "Hov"))])
    }

    @Test func anEditKeepsTheClockWaitingWhileTheTextKeepsChanging() async {
        let rig = Rig()
        rig.paste()
        rig.reader.value = Rig.fixed
        rig.step(0.5)
        rig.step(1.5)
        rig.reader.value = Rig.fixed + " and"
        rig.step(0.5)
        rig.step(1.5)
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.traces.contains { $0.hasPrefix("evaluated") })
    }

    @Test func itNeverEvaluatesWhileTheUserIsTyping() async {
        let rig = Rig()
        rig.paste()
        rig.reader.value = Rig.fixed
        for _ in 0..<8 {
            rig.input.count = (rig.input.count ?? 0) + 1
            rig.step(0.5)
        }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(!rig.traces.contains { $0.hasPrefix("evaluated") } && rig.cards.presented.isEmpty)
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { !rig.cards.presented.isEmpty }
        #expect(rig.cards.presented.count == 1)
    }

    @Test func anUnchangedFieldProposesNothing() async {
        let rig = Rig()
        rig.paste()
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.traces.contains { $0.hasPrefix("evaluated") } }
        #expect(rig.traces.contains("evaluated: 0 proposals, 0 reverted") && rig.cards.presented.isEmpty)
    }

    @Test func theWatchEndsWhenFocusMovesToAnotherElementOrApp() {
        var rig = Rig()
        rig.paste()
        rig.reader.focused = FocusedElement(AXUIElementCreateApplication(101))
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: focus left the field") == true)

        rig = Rig()
        rig.paste()
        rig.reader.pid = 200
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: focus left the app") == true)
    }

    @Test func theWatchEndsWhenTheAppQuitsOrTheFieldGoesSecureOrUnreadable() {
        var rig = Rig()
        rig.paste()
        rig.reader.running = false
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: app quit") == true)

        rig = Rig()
        rig.paste()
        rig.reader.secure = true
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: field became secure") == true)

        rig = Rig()
        rig.paste()
        rig.reader.value = nil
        rig.step(0.5)
        rig.step(0.5)
        #expect(rig.watcher.isWatching)
        rig.step(0.5)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: field unreadable") == true)
    }

    @Test func theWatchEndsAfterThirtySecondsAndWhenAnotherDictationStarts() {
        var rig = Rig()
        rig.paste()
        rig.step(29.9)
        #expect(rig.watcher.isWatching)
        rig.step(0.2)
        #expect(!rig.watcher.isWatching && rig.traces.last?.hasPrefix("stopped: time limit") == true)

        rig = Rig()
        rig.paste()
        rig.watcher.dictationStarted()
        #expect(!rig.watcher.isWatching)
        rig.step(0.5)
        #expect(rig.reader.reads == 1)
    }

    @Test func aNewPasteReplacesTheOldWatch() async {
        let rig = Rig()
        rig.paste("Something else entirely and then some more words")
        rig.paste()
        #expect(rig.watcher.isWatching)
        await rig.editAndWait()
        #expect(rig.cards.presented.count == 1)
    }

    @Test func anOfferWaitsWhileACardIsUpOrADictationRunsThenShows() async {
        let rig = Rig()
        rig.cards.isFree = false
        rig.paste()
        rig.reader.value = Rig.fixed
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.traces.contains { $0.hasPrefix("evaluated") } }
        #expect(rig.cards.presented.isEmpty)
        rig.cards.isFree = true
        rig.state.canOffer = false
        rig.step(0.5)
        #expect(rig.cards.presented.isEmpty)
        rig.state.canOffer = true
        rig.step(0.5)
        #expect(rig.cards.presented.count == 1)
    }

    @Test func aWaitingOfferIsDroppedWhenTheTextMovesOnAndItsFixIsGone() async {
        let rig = Rig()
        rig.cards.isFree = false
        rig.paste()
        rig.reader.value = Rig.fixed
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.traces.contains { $0.hasPrefix("evaluated") } }
        rig.reader.value = Rig.sentence
        rig.step(0.5)
        rig.cards.isFree = true
        rig.step(0.5)
        #expect(rig.cards.presented.isEmpty)
        rig.step(2.1)
        await rig.settle { rig.traces.filter { $0.hasPrefix("evaluated") }.count == 2 }
        rig.step(0.5)
        #expect(rig.cards.presented.isEmpty)
    }

    @Test func aPairAlreadyInTheDictionaryIsNotOffered() async {
        let rig = Rig(rules: #"[{"heard": "hove", "written": "Hov"}]"#)
        rig.paste()
        rig.reader.value = Rig.fixed
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.traces.contains { $0.hasPrefix("evaluated") } }
        rig.step(0.5)
        #expect(rig.cards.presented.isEmpty)
    }

    @Test func aDifferentWrittenFormForAnExistingHeardIsStillOffered() async {
        let rig = Rig(rules: #"[{"heard": "hove", "written": "Hoove"}]"#)
        rig.paste()
        await rig.editAndWait()
        #expect(rig.cards.presented.count == 1)
    }

    // MARK: Answers

    @Test func saveAddsTheRuleRemembersItAsLearnedAndRecordsTheAnswer() async throws {
        let rig = Rig(rules: #"[{"heard": "mouth type", "written": "Mouthtype", "starred": true}]"#)
        rig.paste()
        await rig.editAndWait()
        let card = try #require(rig.cards.presented.first)
        #expect(rig.cards.onOfferAccepted?(card) == true)
        rig.cards.onOfferResolved?(card, .accepted)
        #expect(rig.dictionary.dictionary().map(\.written) == ["Mouthtype", "Hov"])
        #expect(rig.ledger.learned(in: rig.dictionary.dictionary()) == [DictionaryRule(heard: "Hove", written: "Hov")])
        await rig.settle { rig.store.accepted == [true] }
        #expect(rig.store.accepted == [true])
    }

    @Test func saveOnAMalformedFileTouchesNothingAndSaysSo() async throws {
        let rig = Rig(rules: "[oops")
        rig.paste()
        await rig.editAndWait()
        let card = try #require(rig.cards.presented.first)
        #expect(rig.cards.onOfferAccepted?(card) == false)
        #expect(try String(contentsOf: rig.dictionary.url, encoding: .utf8) == "[oops")
        #expect(rig.state.notices == ["dictionary.json has an error"])
        #expect(rig.ledger.learned(in: []).isEmpty)
    }

    @Test func notNowSavesNothingAndCountsAgainstThePair() async throws {
        let rig = Rig()
        rig.paste()
        await rig.editAndWait()
        let card = try #require(rig.cards.presented.first)
        rig.cards.onOfferResolved?(card, .declined)
        #expect(rig.dictionary.dictionary().isEmpty)
        await rig.settle { rig.store.accepted == [false] }
        #expect(rig.store.accepted == [false])
        #expect(!rig.ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }

    @Test func aTimedOutOrReplacedOfferRecordsNoAnswerAndOnlyTimeoutsCountAsDeclines() async throws {
        let rig = Rig()
        rig.paste()
        await rig.editAndWait()
        let card = try #require(rig.cards.presented.first)
        rig.cards.onOfferResolved?(card, .replaced)
        await rig.settle { rig.store.count == 1 }
        #expect(rig.store.accepted == [nil])
        rig.clock.advance(3601)
        #expect(rig.ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }

    @Test func aLearnedRuleChangedBackIsOfferedForRemovalAndForgotten() async throws {
        let rig = Rig(rules: #"[{"heard": "Hove", "written": "Hov"}]"#)
        rig.ledger.recordLearned(heard: "Hove", written: "Hov")
        rig.reader.value = Rig.fixed
        rig.paste(Rig.fixed)
        rig.reader.value = Rig.sentence
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { !rig.cards.presented.isEmpty }
        let card = try #require(rig.cards.presented.first)
        #expect(card == .forgetSpelling(SpellingPair(heard: "Hove", corrected: "Hov")) && card.header == "Forget this spelling?")
        #expect(card.actions == [.forget, .keep])
        #expect(rig.cards.onOfferAccepted?(card) == true)
        #expect(rig.dictionary.dictionary().isEmpty && rig.ledger.learned(in: [DictionaryRule(heard: "Hove", written: "Hov")]).isEmpty)
    }

    @Test func aRuleTheUserWroteIsNeverOfferedForRemoval() async {
        let rig = Rig(rules: #"[{"heard": "Hove", "written": "Hov"}]"#)
        rig.reader.value = Rig.fixed
        rig.paste(Rig.fixed)
        rig.reader.value = Rig.sentence
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.traces.contains { $0.hasPrefix("evaluated") } }
        rig.step(0.5)
        #expect(rig.cards.presented.isEmpty)
    }

    @Test func theSecondFixInTheSameDictationIsOfferedAfterTheFirstIsAnswered() async throws {
        let rig = Rig()
        let pasted = "Hove asked praya to review the plan before the standup"
        rig.reader.value = pasted
        rig.paste(pasted)
        rig.reader.value = "Hov asked Priya to review the plan before the standup"
        rig.step(0.5)
        rig.step(2.1)
        await rig.settle { rig.cards.presented.count == 1 }
        let first = try #require(rig.cards.presented.first)
        #expect(first.pair == SpellingPair(heard: "Hove", corrected: "Hov"))
        _ = rig.cards.onOfferAccepted?(first)
        rig.cards.isFree = true
        rig.cards.onOfferResolved?(first, .accepted)
        rig.step(2.1)
        await rig.settle { rig.cards.presented.count == 2 }
        #expect(rig.cards.presented.last?.pair == SpellingPair(heard: "praya", corrected: "Priya"))
    }

    @Test func nothingFieldRelatedIsEverInTheTrace() async {
        let rig = Rig()
        rig.paste()
        await rig.editAndWait()
        #expect(!rig.traces.contains { $0.contains("Hov") || $0.contains("review") })
    }
}

@MainActor
@Suite struct CorrectionLedgerTests {
    private func ledger(_ clock: LedgerClock, url: URL? = nil) -> CorrectionLedger {
        CorrectionLedger(
            url: url ?? FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json"),
            now: { clock.date }
        )
    }

    @MainActor final class LedgerClock {
        var date = Date(timeIntervalSince1970: 1_800_000_000)
    }

    @Test func aPairIsOfferedAtMostOncePerHourKeyedByTheLowercasedPair() {
        let clock = LedgerClock()
        let ledger = ledger(clock)
        #expect(ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
        ledger.recordOffer(.remember, heard: "Hove", corrected: "Hov")
        #expect(!ledger.canOffer(.remember, heard: "hove", corrected: "HOV"))
        #expect(ledger.canOffer(.remember, heard: "praya", corrected: "Priya"))
        #expect(ledger.canOffer(.forget, heard: "Hove", corrected: "Hov"))
        clock.date.addTimeInterval(3599)
        #expect(!ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
        clock.date.addTimeInterval(2)
        #expect(ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }

    @Test func afterThreeDeclinesThePairIsNeverOfferedAgain() {
        let clock = LedgerClock()
        let ledger = ledger(clock)
        for round in 1...3 {
            #expect(ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"), "round \(round)")
            ledger.recordOffer(.remember, heard: "Hove", corrected: "Hov")
            ledger.recordDecline(.remember, heard: "Hove", corrected: "Hov")
            clock.date.addTimeInterval(3601)
        }
        #expect(!ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
        clock.date.addTimeInterval(86_400 * 365)
        #expect(!ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }

    @Test func theLedgerSurvivesARelaunchAndOnlyTrustsRulesTheDictionaryStillHas() throws {
        let clock = LedgerClock()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("ledger-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let first = ledger(clock, url: url)
        first.recordOffer(.remember, heard: "Hove", corrected: "Hov")
        first.recordDecline(.remember, heard: "Hove", corrected: "Hov")
        first.recordLearned(heard: "praya", written: "Priya")
        let second = ledger(clock, url: url)
        #expect(!second.canOffer(.remember, heard: "Hove", corrected: "Hov"))
        #expect(second.learned(in: [DictionaryRule(heard: "Praya", written: "Priya")]) == [DictionaryRule(heard: "praya", written: "Priya")])
        #expect(second.learned(in: [DictionaryRule(heard: "praya", written: "Priya Singh")]).isEmpty)
        #expect(second.learned(in: []).isEmpty)
        try Data("garbage".utf8).write(to: url)
        #expect(ledger(clock, url: url).canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }

    @Test func savingAPairClearsItsDeclines() {
        let clock = LedgerClock()
        let ledger = ledger(clock)
        ledger.recordDecline(.remember, heard: "Hove", corrected: "Hov")
        ledger.recordLearned(heard: "Hove", written: "Hov")
        #expect(ledger.canOffer(.remember, heard: "Hove", corrected: "Hov"))
    }
}

@MainActor
@Suite struct SpellingCardTests {
    private final class Surface: CardSurface {
        var states: [CardViewState?] = []
        func render(_ state: CardViewState?) { states.append(state) }
        var visible: CardViewState? { states.last ?? nil }
    }

    private final class Clipboard: ClipboardWriting {
        func write(_ text: String) {}
    }

    private let pair = SpellingPair(heard: "Hove", corrected: "Hov")

    private func rig() -> (DeliveryCardPresenter, Surface, FakeClock, Record) {
        let surface = Surface(), clock = FakeClock(start: 0), log = Record()
        let presenter = DeliveryCardPresenter(surface: surface, clipboard: Clipboard(), clock: clock)
        presenter.onOfferResolved = { _, resolution in log.resolutions.append(resolution) }
        return (presenter, surface, clock, log)
    }

    final class Record {
        var resolutions: [OfferResolution] = []
        var accepted: [DeliveryCard.Kind] = []
    }

    private func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }

    @Test func theRememberCardHasItsHeaderBodyAndButtons() {
        let card = DeliveryCard.rememberSpelling(pair)
        #expect(card.header == "Remember this spelling?" && card.pair == pair && card.transcript == nil)
        #expect(card.actions == [.save, .notNow] && card.actions.map(\.title) == ["Save", "Not now"])
        #expect(card.countdown == 8 && card.kind.isOffer)
        #expect(DeliveryCard.forgetSpelling(pair).actions.map(\.title) == ["Forget", "Keep"])
        #expect(!DeliveryCard.pasteFailed("x").kind.isOffer)
    }

    @Test func saveRunsTheHandlerConfirmsInPlaceThenLeaves() async {
        let (presenter, surface, clock, log) = rig()
        presenter.onOfferAccepted = {
            log.accepted.append($0.kind); return true
        }
        presenter.present(.rememberSpelling(pair))
        presenter.perform(.save)
        await settle()
        #expect(log.accepted == [.rememberSpelling] && log.resolutions == [.accepted])
        #expect(surface.visible?.copied == true)
        clock.advance(by: 0.95)
        await settle()
        #expect(surface.visible == nil && log.resolutions == [.accepted])
    }

    @Test func aFailedSaveTakesTheCardDownWithoutConfirming() {
        let (presenter, surface, _, log) = rig()
        presenter.onOfferAccepted = { _ in false }
        presenter.present(.rememberSpelling(pair))
        presenter.perform(.save)
        #expect(surface.visible == nil && surface.states.allSatisfy { $0?.copied != true } && log.resolutions == [.declined])
    }

    @Test func notNowAndTheDismissControlDecline() {
        var (presenter, surface, _, log) = rig()
        presenter.present(.rememberSpelling(pair))
        presenter.perform(.notNow)
        #expect(surface.visible == nil && log.resolutions == [.declined])
        presenter.present(.forgetSpelling(pair))
        presenter.perform(.keep)
        #expect(log.resolutions == [.declined, .declined])
        presenter.present(.rememberSpelling(pair))
        presenter.userDismissed()
        #expect(surface.visible == nil && log.resolutions == [.declined, .declined, .declined])
        (presenter, surface, _, log) = rig()
        presenter.perform(.save)
        #expect(log.resolutions.isEmpty)
    }

    @Test func theCardDismissesItselfAfterEightSecondsAsNotNow() async {
        let (presenter, surface, clock, log) = rig()
        presenter.present(.rememberSpelling(pair))
        await settle()
        clock.advance(by: 7.9)
        await settle()
        #expect(surface.visible != nil && log.resolutions.isEmpty)
        clock.advance(by: 0.2)
        await settle()
        #expect(surface.visible == nil && log.resolutions == [.timedOut])
    }

    @Test func aStaleTimerCannotDismissALaterCard() async {
        let (presenter, surface, clock, log) = rig()
        presenter.present(.rememberSpelling(pair))
        await settle()
        clock.advance(by: 5)
        presenter.present(.rememberSpelling(SpellingPair(heard: "praya", corrected: "Priya")))
        await settle()
        #expect(log.resolutions == [.replaced])
        clock.advance(by: 4)
        await settle()
        #expect(surface.visible?.card.pair?.heard == "praya")
        clock.advance(by: 4.1)
        await settle()
        #expect(surface.visible == nil && log.resolutions == [.replaced, .timedOut])
    }

    @Test func anotherCardOrADismissReplacesTheOfferWithoutAnAnswer() {
        let (presenter, surface, _, log) = rig()
        presenter.present(.rememberSpelling(pair))
        presenter.present(.pasteFailed("x"))
        #expect(log.resolutions == [.replaced] && surface.visible?.card.kind == .pasteFailed)
        presenter.present(.rememberSpelling(pair))
        presenter.dismiss()
        #expect(log.resolutions == [.replaced, .replaced] && surface.visible == nil)
    }

    @Test func otherCardsNeverSeeTheOfferHandlers() {
        let (presenter, _, _, log) = rig()
        presenter.onOfferAccepted = { _ in
            log.accepted.append(.secure); return true
        }
        presenter.present(.pasteFailed("x"))
        presenter.perform(.save)
        presenter.perform(.notNow)
        #expect(log.accepted.isEmpty && log.resolutions.isEmpty)
    }

    @Test func theCardLaysOutWithoutClippingAndTheBodyHoldsTheArrowedPair() {
        _ = NSApplication.shared
        FontRegistry.registerBundledFonts()
        let view = DeliveryCardView(frame: .zero)
        let size = view.render(CardViewState(card: .rememberSpelling(pair)), typography: Typography(choice: .systema))
        let frames = view.frames
        #expect(frames?.buttons.count == 2 && frames?.transcript != nil && frames?.bar != nil)
        #expect(size.width == CardLayout.width + 2 * CardLayout.shadowMargin)
        let long = SpellingPair(heard: "dry dock three", corrected: "Drydock Incorporated Limited")
        view.render(CardViewState(card: .rememberSpelling(long)), typography: Typography(choice: .systema))
        #expect(view.frames?.transcriptScrolls == false)
        #expect((view.frames?.transcript?.height ?? 0) >= 18)
    }
}
