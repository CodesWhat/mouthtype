import Foundation

/// What a field looked like at one read.
struct FieldReading: Equatable, Sendable {
    var value: String?
    var length: Int?
    var selection: NSRange?

    /// All three can be compared.
    var isComplete: Bool { value != nil && length != nil && selection != nil }
}

enum PasteVerdict: Equatable, Sendable {
    /// The field changed, or now holds the pasted text.
    case confirmed
    /// Nothing about the field changed and nothing else could have changed it.
    case notLanded
    /// Can't tell: the field isn't readable, focus moved, or the user did something.
    case unknown

    /// The store's `insert_outcome` vocabulary.
    var storeOutcome: String {
        switch self {
        case .confirmed: "confirmed"
        case .notLanded: "not landed"
        case .unknown: "unknown"
        }
    }
}

/// How a verification ended: for which delivery, and how long the target took to read the paste if it did.
struct PasteVerification: Equatable, Sendable {
    var id: Int
    var verdict: PasteVerdict
    var receiptMs: Int?
}

/// Reads the verdict off what the field looked like before the paste and at each re-read after it.
///
/// Built to stay quiet: a missed failure costs the user nothing they didn't have, a false "didn't land" on a paste
/// that worked makes them doubt a good tool. Only `notLanded` speaks, and it needs every read to agree.
enum PasteVerifier {
    struct Baseline: Equatable, Sendable {
        var reading: FieldReading
        /// How many real key presses and clicks had happened right after the paste; nil when unknown.
        var input: UInt64?
        var unchangedProvesFailure = true
    }

    struct Observation: Equatable, Sendable {
        var reading: FieldReading?
        /// Focus is still on the element the paste went to.
        var focusSame: Bool
        var input: UInt64?
    }

    /// Whether this one read already proves the paste landed.
    static func confirms(_ observation: Observation, baseline: Baseline, pasted: String) -> Bool {
        guard observation.focusSame, let now = observation.reading else { return false }
        let before = baseline.reading
        if let value = now.value, value.contains(pasted), !(before.value?.contains(pasted) ?? false) { return true }
        let changed = differs(before.value, now.value) || differs(before.length, now.length)
            || differs(before.selection, now.selection)
        // A change with typing in between may be the typing, not the paste.
        return changed && observation.input != nil && observation.input == baseline.input
    }

    /// The verdict once every read is in. `expected` is how many reads were planned.
    static func judge(baseline: Baseline?, pasted: String, observations: [Observation], expected: Int) -> PasteVerdict {
        guard let baseline else { return .unknown }
        if observations.contains(where: { confirms($0, baseline: baseline, pasted: pasted) }) { return .confirmed }
        guard baseline.unchangedProvesFailure, observations.count == expected,
              baseline.reading.isComplete, let input = baseline.input else { return .unknown }
        for observation in observations {
            guard observation.focusSame, let now = observation.reading, now.isComplete, observation.input == input,
                  now == baseline.reading else { return .unknown }
        }
        return .notLanded
    }

    private static func differs<T: Equatable>(_ lhs: T?, _ rhs: T?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}
