import Foundation

enum CardAction: Equatable, Sendable {
    case copy, insert, undo, save, notNow, forget, keep

    var title: String {
        switch self {
        case .copy: "Copy"
        case .insert: "Insert"
        case .undo: "Undo"
        case .save: "Save"
        case .notNow: "Not now"
        case .forget: "Forget"
        case .keep: "Keep"
        }
    }
}

/// A spelling the card asks about: what Mouthtype wrote and what the user turned it into.
struct SpellingPair: Equatable, Sendable {
    var heard: String
    var corrected: String
}

/// A card that appears with the pill when text couldn't be delivered or needs a decision.
struct DeliveryCard: Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case secure, nowhere, pasteFailed, cancelled, recovered, rememberSpelling, forgetSpelling

        /// A question about the dictionary rather than a report on a delivery.
        var isOffer: Bool { self == .rememberSpelling || self == .forgetSpelling }
    }

    /// How long Undo stays offered after a cancel.
    static let undoWindow: TimeInterval = 5
    /// How long a card shows "Copied" before it leaves.
    static let copiedHold: TimeInterval = 0.9
    /// How long a spelling question waits for an answer before it counts as "not now".
    static let offerWindow: TimeInterval = 8

    var kind: Kind
    var header: String
    var transcript: String?
    /// The spelling a dictionary card asks about, shown in place of a transcript.
    var pair: SpellingPair? = nil
    var actions: [CardAction]
    /// Seconds the card stays up on its own, shown as a countdown; nil for a card that waits to be dismissed.
    var countdown: TimeInterval?

    static func secure(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .secure, header: "Secure field, not pasted", transcript: text, actions: [.copy], countdown: nil)
    }

    static func nowhere(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .nowhere, header: "Nothing to paste into", transcript: text, actions: [.copy], countdown: nil)
    }

    static func pasteFailed(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .pasteFailed, header: "Paste failed", transcript: text, actions: [.copy], countdown: nil)
    }

    static func cancelled() -> DeliveryCard {
        DeliveryCard(kind: .cancelled, header: "Cancelled", transcript: nil, actions: [.undo], countdown: undoWindow)
    }

    /// For the recovery flow to come: Insert and Copy side by side.
    static func recovered(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .recovered, header: "Recovered a dictation", transcript: text, actions: [.insert, .copy], countdown: nil)
    }

    static func rememberSpelling(_ pair: SpellingPair) -> DeliveryCard {
        DeliveryCard(
            kind: .rememberSpelling, header: "Remember this spelling?", transcript: nil, pair: pair,
            actions: [.save, .notNow], countdown: offerWindow
        )
    }

    /// `pair` is the rule being forgotten: what it hears and what it writes.
    static func forgetSpelling(_ pair: SpellingPair) -> DeliveryCard {
        DeliveryCard(
            kind: .forgetSpelling, header: "Forget this spelling?", transcript: nil, pair: pair,
            actions: [.forget, .keep], countdown: offerWindow
        )
    }

    /// The card a delivery outcome calls for, nil when the text went where it was meant to.
    static func forDelivery(_ result: DeliveryResult, transcript: String) -> DeliveryCard? {
        let text = result.finalText.isEmpty ? transcript : result.finalText
        switch (result.method, result.outcome) {
        case (_, .secureDiscard): return .secure(text)
        case (_, .failed): return .pasteFailed(text)
        case (.clipboardOnly, _): return .nowhere(text)
        default: return nil
        }
    }
}

/// What the card shows right now.
struct CardViewState: Equatable, Sendable {
    var card: DeliveryCard
    /// Copy was clicked and the card is about to leave.
    var copied = false
}
