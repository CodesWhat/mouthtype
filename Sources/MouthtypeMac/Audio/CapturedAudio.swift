import Foundation

public struct CapturedAudio: Sendable, Equatable {
    /// 16 kHz mono Float32, untrimmed.
    public var samples: [Float]
    public var sampleRate: Double
    public var deviceUID: String?
    public var deviceName: String?
    public var deviceTransport: String
    /// Ms from the key press to the first captured sample. Anything said before it is lost. Nil if no audio arrived.
    public var firstSampleMs: Double?
    /// Ms from the key press to the first sample that is not exactly zero.
    public var firstNonzeroMs: Double?
    /// Ms from the key press until the input was running.
    public var captureStartMs: Double
    public var audioMs: Double
    /// The input went away or failed mid-recording, so this is a salvaged partial capture.
    public var wasInterrupted = false
}
