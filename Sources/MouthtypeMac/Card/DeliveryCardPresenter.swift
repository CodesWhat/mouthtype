import AppKit

/// The surface a card is drawn on. `nil` takes the card down.
@MainActor
protocol CardSurface: AnyObject {
    func render(_ state: CardViewState?)
}

@MainActor
protocol ClipboardWriting: AnyObject {
    func write(_ text: String)
}

@MainActor
final class SystemClipboard: ClipboardWriting {
    private let pasteboard: NSPasteboard

    init(_ pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
    }

    /// Copies stay on the clipboard but are kept out of clipboard-manager history, like the app's other copies.
    func write(_ text: String) {
        SystemPasteboard(pasteboard).write(text, markers: PasteboardSession.concealedMarkers)
    }
}

/// What the controller needs from the card.
@MainActor
protocol DictationCards: AnyObject {
    /// `actions` are what Insert, Recover and Discard do for this card alone; they go when the card does.
    func present(_ card: DeliveryCard, actions: [CardAction: @MainActor () -> Void])
    func dismiss()
    /// Undo was clicked.
    var onUndo: (@MainActor () -> Void)? { get set }
    /// The dismiss control was clicked.
    var onDismissed: (@MainActor (DeliveryCard) -> Void)? { get set }
    /// The card up changed: the new card on a present (a replacement included), nil when the card goes by any route.
    var onCardChange: (@MainActor (DeliveryCard?) -> Void)? { get set }
}

extension DictationCards {
    func present(_ card: DeliveryCard) { present(card, actions: [:]) }
}

/// How a spelling question ended.
enum OfferResolution: Equatable, Sendable {
    /// Save or Forget was clicked and the dictionary took it.
    case accepted
    /// Not now, Keep or the dismiss control.
    case declined
    /// Nobody answered in time; counts as "not now".
    case timedOut
    /// A dictation or another card took the place before an answer.
    case replaced
}

/// Which card is up and what a click on it does. One card at a time: a new one replaces the old. Copy confirms in
/// place and then the card leaves; the other actions hand off and take it down.
@MainActor
final class DeliveryCardPresenter: DictationCards {
    private let surface: any CardSurface
    private let clipboard: any ClipboardWriting
    private let clock: any DictationClock
    private(set) var state: CardViewState?
    private var generation = 0

    var onUndo: (@MainActor () -> Void)?
    var onCardChange: (@MainActor (DeliveryCard?) -> Void)?
    var onInsert: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?
    /// Save or Forget was clicked: do it, and say whether it worked. A false leaves the card down with no confirmation.
    var onOfferAccepted: (@MainActor (DeliveryCard) -> Bool)?
    /// A spelling question ended, once, however it ended.
    var onOfferResolved: (@MainActor (DeliveryCard, OfferResolution) -> Void)?
    private var openOffer: DeliveryCard?
    private var handlers: [CardAction: @MainActor () -> Void] = [:]

    init(surface: any CardSurface, clipboard: any ClipboardWriting, clock: any DictationClock) {
        self.surface = surface
        self.clipboard = clipboard
        self.clock = clock
    }

    func present(_ card: DeliveryCard, actions: [CardAction: @MainActor () -> Void] = [:]) {
        resolveOffer(.replaced)
        handlers = actions
        generation += 1
        state = CardViewState(card: card)
        surface.render(state)
        onCardChange?(card)
        guard card.kind.isOffer else { return }
        openOffer = card
        let shown = generation
        Task { @MainActor [weak self, clock] in
            try? await clock.sleep(forSeconds: card.countdown ?? DeliveryCard.offerWindow)
            guard let self, self.generation == shown, self.openOffer != nil else { return }
            self.resolveOffer(.timedOut)
            self.dismiss()
        }
    }

    func dismiss() {
        resolveOffer(.replaced)
        handlers = [:]
        generation += 1
        guard state != nil else { return }
        state = nil
        surface.render(nil)
        onCardChange?(nil)
    }

    private func resolveOffer(_ resolution: OfferResolution) {
        guard let card = openOffer else { return }
        openOffer = nil
        onOfferResolved?(card, resolution)
    }

    func perform(_ action: CardAction) {
        guard let current = state, current.card.actions.contains(action), !current.copied else { return }
        switch action {
        case .copy:
            clipboard.write(current.card.transcript ?? "")
            generation += 1
            let shown = generation
            state?.copied = true
            surface.render(state)
            Task { @MainActor [weak self, clock] in
                try? await clock.sleep(forSeconds: DeliveryCard.copiedHold)
                guard let self, self.generation == shown else { return }
                self.dismiss()
            }
        case .undo:
            dismiss()
            onUndo?()
        case .insert, .recover, .discard, .openSoundSettings:
            let handler = handlers[action]
            dismiss()
            if action == .insert { onInsert?() }
            handler?()
        case .save, .forget:
            guard onOfferAccepted?(current.card) ?? true else {
                resolveOffer(.declined)
                dismiss()
                return
            }
            resolveOffer(.accepted)
            generation += 1
            let shown = generation
            state?.copied = true
            surface.render(state)
            Task { @MainActor [weak self, clock] in
                try? await clock.sleep(forSeconds: DeliveryCard.copiedHold)
                guard let self, self.generation == shown else { return }
                self.dismiss()
            }
        case .notNow, .keep:
            resolveOffer(.declined)
            dismiss()
        }
    }

    /// The dismiss control.
    func userDismissed() {
        guard let card = state?.card else { return }
        resolveOffer(.declined)
        dismiss()
        onDismissed?(card)
    }
}
