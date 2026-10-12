import Foundation

/// What the pill says: a headline, and when there is more to tell, a detail on its own line under it.
struct PillMessage: Equatable, Sendable {
    var headline: String
    var detail: String?
    var isError: Bool

    init(_ headline: String, detail: String? = nil, isError: Bool = false) {
        self.headline = headline
        self.detail = detail
        self.isError = isError
    }

    /// The one-line form for a skin that scrolls its text, such as the hi-fi readout.
    var singleLine: String {
        guard let detail, !detail.isEmpty else { return headline }
        return "\(headline) - \(detail)"
    }
}
