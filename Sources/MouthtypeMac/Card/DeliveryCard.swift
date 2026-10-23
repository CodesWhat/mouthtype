import Foundation
import MouthtypeCore

enum CardAction: Equatable, Sendable {
    case copy, insert, undo, save, notNow, forget, keep, recover, discard, openSoundSettings

    var title: String {
        switch self {
        case .copy: "Copy"
        case .insert: "Insert"
        case .undo: "Undo"
        case .save: "Save"
        case .notNow: "Not now"
        case .forget: "Forget"
        case .keep: "Keep"
        case .recover: "Recover"
        case .discard: "Discard"
        case .openSoundSettings: "Sound settings"
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
        case recoverOffer, micDisconnected, limitWarning, silentMic

        /// A question about the dictionary rather than a report on a delivery.
        var isOffer: Bool { self == .rememberSpelling || self == .forgetSpelling }

        /// A card that asks the user something, so a skin can mark it with a question accent.
        var isQuestion: Bool { isOffer || self == .recoverOffer }

        /// A card that asks or reports something good rather than a failure, so it wears the quiet ink, not the error red.
        var isQuiet: Bool { isOffer || self == .recoverOffer || self == .recovered }
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

    /// What the pill says under this card, so it adds to the header instead of repeating it: the header's detail line
    /// when it has one, else that the transcript is safe, else nothing.
    var pillMessage: PillMessage? {
        let lines = header.split(separator: "\n", omittingEmptySubsequences: true)
        let text: String
        if lines.count > 1 {
            text = String(lines[1])
        } else if transcript != nil {
            text = Self.textIsSafe
        } else {
            return nil
        }
        return PillMessage(text, isError: !kind.isQuiet)
    }

    static let textIsSafe = "Your text is safe"

    static func secure(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .secure, header: "Secure field, not pasted", transcript: text, actions: [.copy], countdown: nil)
    }

    static func nowhere(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .nowhere, header: "Nothing to paste into", transcript: text, actions: [.copy], countdown: nil)
    }

    static func pasteFailed(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .pasteFailed, header: "Paste failed", transcript: text, actions: [.copy], countdown: nil)
    }

    /// The read-back found the field unchanged after a paste. It reuses the failure kind: same colour, same Copy.
    static func notLanded(_ text: String) -> DeliveryCard {
        DeliveryCard(
            kind: .pasteFailed, header: "Paste didn't land\nThe field didn't change", transcript: text,
            actions: [.copy], countdown: nil
        )
    }

    static func cancelled() -> DeliveryCard {
        DeliveryCard(kind: .cancelled, header: "Cancelled", transcript: nil, actions: [.undo], countdown: undoWindow)
    }

    /// The result of a recovery. Copy only: the focus at launch isn't where the dictation was meant to go.
    static func recovered(_ text: String) -> DeliveryCard {
        DeliveryCard(kind: .recovered, header: "Recovered a dictation", transcript: text, actions: [.copy], countdown: nil)
    }

    /// A launch found a dictation a crash cut off. `ago` is the age of the dictation, `older` how many more were set aside.
    static func recoverOffer(seconds: Double, ago: TimeInterval, older: Int) -> DeliveryCard {
        var header = "Recover your last dictation?\n\(durationText(seconds)), \(agoText(ago))"
        if older > 0 { header += "\nand \(older) older \(older == 1 ? "one" : "ones") in Saved Recordings" }
        return DeliveryCard(kind: .recoverOffer, header: header, transcript: nil, actions: [.recover, .discard], countdown: nil)
    }

    /// The input went away mid-recording; what was captured is saved and waits for Insert or Discard.
    static func micDisconnected(seconds: Double) -> DeliveryCard {
        let count = max(1, Int(seconds.rounded()))
        return DeliveryCard(
            kind: .micDisconnected, header: "Microphone disconnected\n\(count) \(count == 1 ? "second" : "seconds") recorded",
            transcript: nil, actions: [.insert, .discard], countdown: nil
        )
    }

    /// A minute before a recording is stopped for length.
    static func limitWarning(stopsAfter: TimeInterval) -> DeliveryCard {
        DeliveryCard(
            kind: .limitWarning, header: "One minute left\nRecording stops at \(durationText(stopsAfter))", transcript: nil,
            actions: [], countdown: nil
        )
    }

    /// A take that heard nothing. `micName` is the input that was recording, so the fix starts with the right device.
    static func silentMic(_ kind: SilentTakeKind, micName: String?) -> DeliveryCard {
        let mic = micName.flatMap { $0.isEmpty ? nil : $0 } ?? "your microphone"
        let header = kind == .noSignal ? "Microphone heard nothing" : "No speech heard"
        return DeliveryCard(
            kind: .silentMic, header: "\(header)\nCheck \(mic)", transcript: nil,
            actions: [.openSoundSettings], countdown: nil
        )
    }

    static func durationText(_ seconds: Double) -> String {
        let total = max(1, Int(seconds.rounded()))
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s")" }
        guard total >= 60 else { return unit(total, "second") }
        let minutes = total / 60, rest = total % 60
        return rest == 0 ? unit(minutes, "minute") : "\(unit(minutes, "minute")) \(unit(rest, "second"))"
    }

    static func agoText(_ age: TimeInterval) -> String {
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        if age < 60 { return "just now" }
        if age < 3600 { return unit(Int(age / 60), "minute") }
        return unit(Int(age / 3600), "hour")
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

    /// The card a verdict calls for. Only "not landed" speaks.
    static func forVerdict(_ verdict: PasteVerdict, transcript: String) -> DeliveryCard? {
        verdict == .notLanded ? .notLanded(transcript) : nil
    }

    /// The card a delivery outcome calls for, nil when the text went where it was meant to.
    static func forDelivery(_ result: DeliveryResult, transcript: String) -> DeliveryCard? {
        let text = result.finalText.isEmpty ? transcript : result.finalText
        switch (result.method, result.outcome) {
        case (_, .secureDiscard): return .secure(text)
        case (_, .partialPaste):
            return DeliveryCard(
                kind: .pasteFailed, header: "Paste stopped\nSome text may already be there", transcript: text,
                actions: [.copy], countdown: nil)
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
