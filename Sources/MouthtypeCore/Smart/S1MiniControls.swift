import Foundation

/// S1-mini by Superwhisper steers on one control line above the transcript. These are its three axes, with the
/// values the model card lists as trained.
public struct S1MiniControls: Sendable, Equatable, Hashable {
    public enum Styling: String, Sendable, CaseIterable {
        case casual
        case semiCasual = "semi-casual"
        case semiFormal = "semi-formal"
        case formal
    }

    public enum Structure: String, Sendable, CaseIterable {
        case prose, lists
    }

    public enum Destination: String, Sendable, CaseIterable {
        case general, email
    }

    public var styling: Styling
    public var structure: Structure
    public var destination: Destination

    public init(styling: Styling = .semiFormal, structure: Structure = .lists, destination: Destination = .general) {
        self.styling = styling
        self.structure = structure
        self.destination = destination
    }

    /// What the cleanup benchmark ran with.
    public static let benchmark = S1MiniControls()

    public var line: String {
        "[Styling: \(styling.rawValue)] [Structure: \(structure.rawValue)] [Context: \(destination.rawValue)]"
    }

    /// Bundle ids of mail apps, where the email layout applies.
    static let mailBundleIDs: Set<String> = [
        "com.apple.mail", "com.microsoft.Outlook", "com.readdle.smartemail-Mac", "com.superhuman.electron",
    ]

    public static func destination(forBundleID bundleID: String?) -> Destination {
        bundleID.map(mailBundleIDs.contains) == true ? .email : .general
    }
}
