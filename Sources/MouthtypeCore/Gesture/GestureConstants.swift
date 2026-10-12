// Adapted from Hex (https://github.com/kitlangton/Hex, f58d52c), MIT License, Copyright (c) 2025 Kit Langton.

import Foundation

/// Timing thresholds for the hotkey state machine, trimmed from Hex's HexCoreConstants.
public enum GestureConstants {
    /// Maximum time between two taps to count as a double-tap.
    public static let doubleTapWindow: TimeInterval = 0.3

    /// Minimum hold for modifier-only hotkeys, so quick taps and Option-click style shortcuts never transcribe.
    public static let modifierOnlyMinimumDuration: TimeInterval = 0.3

    /// Window in which a different key press cancels a key+modifier hotkey.
    public static let pressAndHoldCancelWindow: TimeInterval = 1.0

    public static let defaultMinimumKeyTime: TimeInterval = 0.2
}
