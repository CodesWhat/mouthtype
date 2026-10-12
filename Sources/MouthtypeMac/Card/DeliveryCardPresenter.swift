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
    func write(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}

/// What the controller needs from the card.
@MainActor
protocol DictationCards: AnyObject {
    func present(_ card: DeliveryCard)
    func dismiss()
    /// Undo was clicked.
    var onUndo: (@MainActor () -> Void)? { get set }
    /// The dismiss control was clicked.
    var onDismissed: (@MainActor (DeliveryCard) -> Void)? { get set }
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
    var onInsert: (@MainActor () -> Void)?
    var onDismissed: (@MainActor (DeliveryCard) -> Void)?

    init(surface: any CardSurface, clipboard: any ClipboardWriting, clock: any DictationClock) {
        self.surface = surface
        self.clipboard = clipboard
        self.clock = clock
    }

    func present(_ card: DeliveryCard) {
        generation += 1
        state = CardViewState(card: card)
        surface.render(state)
    }

    func dismiss() {
        generation += 1
        guard state != nil else { return }
        state = nil
        surface.render(nil)
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
        case .insert:
            dismiss()
            onInsert?()
        }
    }

    /// The dismiss control.
    func userDismissed() {
        guard let card = state?.card else { return }
        dismiss()
        onDismissed?(card)
    }
}
