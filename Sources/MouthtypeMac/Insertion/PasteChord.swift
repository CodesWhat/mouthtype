import CoreGraphics

enum PasteChord: String, CaseIterable, Sendable {
    case commandV = "command-v"
    case commandShiftV = "command-shift-v"
    case controlShiftV = "control-shift-v"

    var title: String {
        switch self {
        case .commandV: "Command-V (Default)"
        case .commandShiftV: "Command-Shift-V"
        case .controlShiftV: "Control-Shift-V"
        }
    }

    var flags: CGEventFlags {
        switch self {
        case .commandV: .maskCommand
        case .commandShiftV: [.maskCommand, .maskShift]
        case .controlShiftV: [.maskControl, .maskShift]
        }
    }
}
