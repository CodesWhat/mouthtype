import AppKit
import Foundation
import MouthtypeCore

/// The Accessibility reads a watch repeats. The system in the app, a fake in tests.
@MainActor
protocol CorrectionFieldReading: AnyObject {
    func probe() -> FocusProbe
    func value(of element: FocusedElement) -> String?
    func isRunning(pid: pid_t) -> Bool
    var isSecureInputEnabled: Bool { get }
}

@MainActor
final class AccessibilityFieldReader: CorrectionFieldReading {
    private let reader: AccessibilityFocusReader

    init(reader: AccessibilityFocusReader = AccessibilityFocusReader()) {
        self.reader = reader
    }

    func probe() -> FocusProbe { reader.probe() }
    func value(of element: FocusedElement) -> String? { reader.fieldValue(of: element) }
    func isRunning(pid: pid_t) -> Bool { NSRunningApplication(processIdentifier: pid) != nil }
    var isSecureInputEnabled: Bool { reader.isSecureInputEnabled }
}

protocol CorrectionDictionary: AnyObject {
    func dictionary() -> [DictionaryRule]
    func save(heard: String, written: String) throws -> FileVocabulary.SaveResult
    func remove(heard: String) throws -> Bool
}

extension FileVocabulary: CorrectionDictionary {}

/// Where offers are written down. Async so the real store's blocking calls stay off the main actor.
protocol CorrectionStoring: Sendable {
    func offered(dictationID: String, kind: CorrectionKind, heard: String, corrected: String) async -> Int64?
    func resolved(_ id: Int64, accepted: Bool?) async
}

struct CorrectionStoreWriter: CorrectionStoring {
    let store: TranscriptStore

    func offered(dictationID: String, kind: CorrectionKind, heard: String, corrected: String) async -> Int64? {
        do {
            return try store.recordCorrectionOffer(dictationID: dictationID, kind: kind, heard: heard, corrected: corrected)
        } catch {
            Log.corrections.error("offer not recorded: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    func resolved(_ id: Int64, accepted: Bool?) async {
        do {
            try store.recordCorrectionOutcome(id, accepted: accepted)
        } catch {
            Log.corrections.error("outcome not recorded: \(String(describing: error), privacy: .public)")
        }
    }
}

/// The card surface offers go through: the delivery card presenter in the app.
@MainActor
protocol CorrectionCards: AnyObject {
    /// No card is showing.
    var isFree: Bool { get }
    func present(_ card: DeliveryCard)
    var onOfferAccepted: (@MainActor (DeliveryCard) -> Bool)? { get set }
    var onOfferResolved: (@MainActor (DeliveryCard, OfferResolution) -> Void)? { get set }
}

extension DeliveryCardPresenter: CorrectionCards {
    var isFree: Bool { state == nil }
}

/// What the dictation controller tells the watcher.
@MainActor
protocol CorrectionObserving: AnyObject {
    func pasted(_ text: String, dictationID: String, target: FocusSnapshot?)
    func dictationStarted()
    /// The read-back found the field unchanged after this dictation's paste, so there is nothing to watch.
    func pasteDidNotLand(dictationID: String)
}

/// After a paste into a readable field, polls that field for up to 30 s. Once the text has held still for 2 s and the
/// user has stopped typing, it asks `CorrectionLearner` whether an edit looks like a vocabulary fix and offers it on
/// a card. The field text lives in memory for the comparison only: it is never logged or stored, and only the word
/// pair that comes out is kept.
@MainActor
final class CorrectionWatcher: CorrectionObserving {
    static let pollInterval: TimeInterval = 0.5
    static let watchLimit: TimeInterval = 30
    static let stableFor: TimeInterval = 2
    static let maxReadFailures = 3

    private struct Offer: Equatable {
        var kind: CorrectionKind
        var pair: SpellingPair
        var dictationID: String

        var key: String { "\(kind.rawValue)|\(pair.heard.lowercased())|\(pair.corrected.lowercased())" }
        var card: DeliveryCard { kind == .remember ? .rememberSpelling(pair) : .forgetSpelling(pair) }
    }

    private struct Watch {
        var id: Int
        var dictationID: String
        var pasted: String
        var pid: pid_t
        var element: FocusedElement
        var startedAt: Date
        var lastValue: String?
        var changedAt: Date
        var lastInput: UInt64?
        var inputAt: Date
        var evaluatedValue: String?
        var evaluating = false
        var failures = 0
        var polls = 0
        var offered: Set<String> = []
        var pending: Offer?
    }

    private struct ActiveOffer {
        var offer: Offer
        var record: Task<Int64?, Never>
    }

    private let reader: any CorrectionFieldReading
    private let dictionary: any CorrectionDictionary
    private let ledger: CorrectionLedger
    private let store: (any CorrectionStoring)?
    private let cards: any CorrectionCards
    private let clock: any DictationClock
    private let input: @MainActor () -> UInt64?
    private let isEnabled: @MainActor () -> Bool
    private let canOffer: @MainActor () -> Bool
    private var watch: Watch?
    private var active: ActiveOffer?
    private var loop: Task<Void, Never>?
    private var nextID = 0

    /// A debug trace of what the watcher did, with no field text in it.
    var onTrace: (@MainActor (String) -> Void)?
    /// A card action that couldn't be carried out, for the pill to say.
    var onNotice: (@MainActor (PillMessage) -> Void)?

    init(
        reader: any CorrectionFieldReading, dictionary: any CorrectionDictionary, ledger: CorrectionLedger,
        store: (any CorrectionStoring)?, cards: any CorrectionCards, clock: any DictationClock,
        input: @escaping @MainActor () -> UInt64?, isEnabled: @escaping @MainActor () -> Bool = { CorrectionSettings.isEnabled() },
        canOffer: @escaping @MainActor () -> Bool
    ) {
        self.reader = reader
        self.dictionary = dictionary
        self.ledger = ledger
        self.store = store
        self.cards = cards
        self.clock = clock
        self.input = input
        self.isEnabled = isEnabled
        self.canOffer = canOffer
        cards.onOfferAccepted = { [weak self] card in self?.accept(card) ?? false }
        cards.onOfferResolved = { [weak self] card, resolution in self?.resolve(card, resolution) }
    }

    var isWatching: Bool { watch != nil }

    // MARK: Starting and stopping

    func pasted(_ text: String, dictationID: String, target: FocusSnapshot?) {
        stop("new paste")
        guard isEnabled() else { return }
        guard let target, !target.isSecure, let pid = target.pid, let element = target.element else {
            trace("not watching: no readable field")
            return
        }
        guard let first = reader.value(of: element) else {
            trace("not watching: field value unreadable")
            return
        }
        guard first.count <= CorrectionLearner.maxFieldCharacters else {
            trace("not watching: field too large")
            return
        }
        let now = clock.now()
        nextID += 1
        watch = Watch(
            id: nextID, dictationID: dictationID, pasted: text, pid: pid, element: element, startedAt: now,
            lastValue: first, changedAt: now, lastInput: input(), inputAt: now
        )
        trace("watching")
        let generation = nextID
        loop = Task { [weak self, clock] in
            while !Task.isCancelled {
                do { try await clock.sleep(forSeconds: Self.pollInterval) } catch { return }
                guard let self, !Task.isCancelled, self.watch?.id == generation else { return }
                self.tick()
            }
        }
    }

    func dictationStarted() {
        stop("another dictation started")
    }

    func pasteDidNotLand(dictationID: String) {
        guard watch?.dictationID == dictationID else { return }
        stop("paste didn't land")
    }

    private func stop(_ reason: String) {
        loop?.cancel()
        loop = nil
        guard let ended = watch else { return }
        watch = nil
        trace("stopped: \(reason) after \(ended.polls) polls")
    }

    // MARK: Polling

    func tick() {
        guard var w = watch else { return }
        guard isEnabled() else { return stop("setting off") }
        let now = clock.now()
        guard now.timeIntervalSince(w.startedAt) < Self.watchLimit else { return stop("time limit") }
        guard reader.isRunning(pid: w.pid) else { return stop("app quit") }
        let probe = reader.probe()
        guard probe.pid == w.pid else { return stop("focus left the app") }
        if let element = probe.element, element != w.element { return stop("focus left the field") }
        if probe.isSecure || (probe.element == nil && reader.isSecureInputEnabled) { return stop("field became secure") }

        w.polls += 1
        guard let value = reader.value(of: w.element) else {
            w.failures += 1
            watch = w
            if w.failures >= Self.maxReadFailures { stop("field unreadable") }
            return
        }
        w.failures = 0
        guard value.count <= CorrectionLearner.maxFieldCharacters else { return stop("field too large") }
        let typed = input()
        if typed != w.lastInput {
            w.lastInput = typed
            w.inputAt = now
        }
        if value != w.lastValue {
            w.lastValue = value
            w.changedAt = now
            trace("field changed (\(value.count) characters)")
        }
        watch = w

        let quiet = now.timeIntervalSince(max(w.changedAt, w.inputAt))
        if quiet >= Self.stableFor, value != w.evaluatedValue, !w.evaluating {
            evaluate(value)
        }
        presentPending()
    }

    // MARK: Evaluating

    private func evaluate(_ value: String) {
        guard var w = watch else { return }
        w.evaluating = true
        w.evaluatedValue = value
        watch = w
        let pasted = w.pasted
        let generation = w.id
        let learned = ledger.learned(in: dictionary.dictionary())
        Task { [weak self] in
            let analysis = await Self.analyse(pasted: pasted, field: value, learned: learned)
            self?.evaluated(analysis, generation: generation)
        }
    }

    @concurrent
    private static func analyse(pasted: String, field: String, learned: [DictionaryRule]) async -> CorrectionAnalysis {
        CorrectionLearner.analyse(pasted: pasted, field: field, learned: learned)
    }

    private func evaluated(_ analysis: CorrectionAnalysis, generation: Int) {
        guard var w = watch, w.id == generation else { return }
        w.evaluating = false
        trace("evaluated: \(analysis.proposals.count) proposals, \(analysis.reverted.count) reverted")
        let rules = dictionary.dictionary()
        var found: Offer?
        for rule in analysis.reverted {
            let offer = Offer(kind: .forget, pair: SpellingPair(heard: rule.heard, corrected: rule.written), dictationID: w.dictationID)
            if !w.offered.contains(offer.key), ledger.canOffer(.forget, heard: rule.heard, corrected: rule.written) {
                found = offer
                break
            }
        }
        if found == nil {
            for proposal in analysis.proposals {
                let offer = Offer(kind: .remember, pair: SpellingPair(heard: proposal.heard, corrected: proposal.corrected), dictationID: w.dictationID)
                let known = rules.contains { $0.heard.lowercased() == proposal.heard.lowercased() && $0.written == proposal.corrected }
                // A rule the user wrote, turned back by the user: that is for the dictionary file, not a new rule.
                let reversed = rules.contains {
                    $0.heard.lowercased() == proposal.corrected.lowercased() && $0.written.lowercased() == proposal.heard.lowercased()
                }
                if !known, !reversed, !w.offered.contains(offer.key), ledger.canOffer(.remember, heard: proposal.heard, corrected: proposal.corrected) {
                    found = offer
                    break
                }
            }
        }
        w.pending = found
        watch = w
        presentPending()
    }

    // MARK: Offering

    /// One offer waits at most; it is shown only while nothing else is on screen and no dictation is running, and
    /// only if the field still holds the text it was found in.
    private func presentPending() {
        guard var w = watch, let offer = w.pending, !w.evaluating, w.lastValue == w.evaluatedValue,
              cards.isFree, canOffer() else { return }
        w.pending = nil
        w.offered.insert(offer.key)
        watch = w
        ledger.recordOffer(offer.kind, heard: offer.pair.heard, corrected: offer.pair.corrected)
        let store = store
        let record = Task { await store?.offered(dictationID: offer.dictationID, kind: offer.kind, heard: offer.pair.heard, corrected: offer.pair.corrected) }
        active = ActiveOffer(offer: offer, record: record)
        trace("offer shown: \(offer.kind.rawValue)")
        cards.present(offer.card)
    }

    private func accept(_ card: DeliveryCard) -> Bool {
        guard let pair = card.pair else { return false }
        do {
            switch card.kind {
            case .rememberSpelling:
                let result = try dictionary.save(heard: pair.heard, written: pair.corrected)
                if result != .unchanged { ledger.recordLearned(heard: pair.heard, written: pair.corrected) }
                trace("dictionary \(result)")
            case .forgetSpelling:
                _ = try dictionary.remove(heard: pair.heard)
                ledger.recordForgotten(heard: pair.heard)
                trace("dictionary rule removed")
            default:
                return false
            }
            return true
        } catch FileVocabulary.WriteError.malformed(let message) {
            Log.corrections.error("dictionary not changed: file has an error")
            onNotice?(PillMessage("dictionary.json has an error", detail: message, isError: true))
        } catch {
            Log.corrections.error("dictionary not changed: \(String(describing: error), privacy: .public)")
            onNotice?(PillMessage("Couldn't update the dictionary", detail: "Try again", isError: true))
        }
        return false
    }

    private func resolve(_ card: DeliveryCard, _ resolution: OfferResolution) {
        guard let current = active else { return }
        active = nil
        let accepted: Bool? = switch resolution {
        case .accepted: true
        case .declined: false
        case .timedOut, .replaced: nil
        }
        if resolution == .declined || resolution == .timedOut {
            ledger.recordDecline(current.offer.kind, heard: current.offer.pair.heard, corrected: current.offer.pair.corrected)
        }
        trace("offer ended: \(resolution)")
        let store = store
        Task {
            if let id = await current.record.value { await store?.resolved(id, accepted: accepted) }
        }
        // The next fix in the same dictation can be offered once this one is out of the way.
        if var w = watch {
            w.evaluatedValue = nil
            watch = w
        }
    }

    private func trace(_ line: String) {
        Log.corrections.info("\(line, privacy: .public)")
        onTrace?(line)
    }
}
