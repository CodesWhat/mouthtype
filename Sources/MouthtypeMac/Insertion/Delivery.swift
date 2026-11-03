// Adapted from Parrot (https://github.com/humanitas-labs/parrot, 0eb4708), MIT License, Copyright (c) 2026 Humanitas Labs.
import Foundation

/// Where a finished transcript goes. Pure, so it is tested.
enum DeliveryDecision: Equatable {
    /// Paste at the cursor, wherever focus is now.
    case paste
    /// The focused field at delivery is secure, or it can't be read while secure input is on: drop the transcript.
    case discardSecure
    /// Nothing is frontmost to paste into: leave the transcript on the clipboard.
    case clipboardOnly

    /// Only the field at delivery counts. Other apps leave Secure Input on, so with it on a paste needs a field
    /// confirmed as ordinary text: a readable text role and subrole, not secure or protected. Containers, unknown roles
    /// and timed-out reads can't rule out a password field, so those discard.
    static func decide(now: FocusSnapshot, secureInput: Bool) -> DeliveryDecision {
        if now.isSecure || (secureInput && !now.isConfirmedNormalField) { return .discardSecure }
        if now.pid == nil { return .clipboardOnly }
        return .paste
    }
}

public struct DeliveryResult: Sendable {
    public enum Method: Sendable, Equatable { case paste, clipboardOnly, none }
    public enum Outcome: Sendable, Equatable { case unknown, secureDiscard, failed(String), partialPaste }

    public var method: Method
    public var outcome: Outcome
    public var focusMoved: Bool
    /// Focus at delivery.
    public var target: FocusSnapshot?
    /// What was pasted or copied, with any spacing applied. Empty when nothing was delivered.
    public var finalText: String
    /// Milliseconds from the paste chord to the target app reading the clipboard. Nil when it hadn't by the time
    /// delivery returned, which is nearly always: the receipt arrives with the verification.
    public var pasteReceiptMs: Int? = nil
    /// Names the read-back verification started for this paste, when one was.
    var verificationID: Int? = nil
    /// A secure discard caused by system Secure Input being on while the field wasn't confirmed as ordinary text, not
    /// by the field itself being secure.
    public var secureInputBlocked: Bool = false

    /// The store's `insert_method` vocabulary.
    public var storeMethod: String {
        switch method {
        case .paste: "paste"
        case .clipboardOnly: "clipboard only"
        case .none: "none"
        }
    }

    /// The store's `insert_outcome` vocabulary.
    public var storeOutcome: String {
        switch outcome {
        case .unknown, .partialPaste: "unknown"
        case .secureDiscard: "secure discard"
        case .failed: "not landed"
        }
    }
}
