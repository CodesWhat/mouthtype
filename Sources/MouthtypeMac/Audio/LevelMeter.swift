import Foundation
import Synchronization

/// What the meter hears right now, in dBFS: the short-term RMS and the same signal split into three bands.
public struct LevelReading: Sendable, Equatable {
    public static let floorDb: Float = -120

    public var db: Float
    public var low: Float
    public var mid: Float
    public var high: Float

    public init(db: Float, low: Float? = nil, mid: Float? = nil, high: Float? = nil) {
        self.db = db
        self.low = low ?? db
        self.mid = mid ?? db
        self.high = high ?? db
    }

    public static let silence = LevelReading(db: floorDb)
}

/// The input level in dBFS, written by the render callback and read from the main thread. Atomic words only, so
/// neither side takes a lock. Only the render thread calls `update`, so its filter state needs no more than that.
///
/// The three bands come from two low-pass filters on the 16 kHz stream (each two one-pole stages in a row, corners
/// at 400 Hz and 3 kHz): low is the first, mid the difference, high what is left of the input. That is a few
/// multiplies per sample and no FFT; it separates vowel weight from sibilance well enough to make the bars differ.
final class LevelMeter: Sendable {
    static let sampleRate: Float = 16_000
    static let lowCutoff: Float = 400
    static let highCutoff: Float = 3_000

    private let dbBits = Atomic<UInt32>(LevelReading.floorDb.bitPattern)
    private let lowBits = Atomic<UInt32>(LevelReading.floorDb.bitPattern)
    private let midBits = Atomic<UInt32>(LevelReading.floorDb.bitPattern)
    private let highBits = Atomic<UInt32>(LevelReading.floorDb.bitPattern)
    private let lowStateA = Atomic<UInt32>(0)
    private let lowStateB = Atomic<UInt32>(0)
    private let highStateA = Atomic<UInt32>(0)
    private let highStateB = Atomic<UInt32>(0)

    var reading: LevelReading {
        LevelReading(
            db: Float(bitPattern: dbBits.load(ordering: .relaxed)),
            low: Float(bitPattern: lowBits.load(ordering: .relaxed)),
            mid: Float(bitPattern: midBits.load(ordering: .relaxed)),
            high: Float(bitPattern: highBits.load(ordering: .relaxed))
        )
    }

    static func decibels(_ rms: Float) -> Float {
        max(LevelReading.floorDb, 20 * log10(max(rms, 1e-6)))
    }

    static func coefficient(cutoff: Float) -> Float {
        1 - exp(-2 * .pi * cutoff / sampleRate)
    }

    /// One chunk of 16 kHz mono samples.
    func update<C: Collection>(samples: C) where C.Element == Float {
        guard !samples.isEmpty else { return }
        let a1 = Self.coefficient(cutoff: Self.lowCutoff)
        let a2 = Self.coefficient(cutoff: Self.highCutoff)
        var s1 = Float(bitPattern: lowStateA.load(ordering: .relaxed))
        var s1b = Float(bitPattern: lowStateB.load(ordering: .relaxed))
        var s2 = Float(bitPattern: highStateA.load(ordering: .relaxed))
        var s2b = Float(bitPattern: highStateB.load(ordering: .relaxed))
        var total: Float = 0, low: Float = 0, mid: Float = 0, high: Float = 0
        for x in samples {
            s1 += a1 * (x - s1)
            s1b += a1 * (s1 - s1b)
            s2 += a2 * (x - s2)
            s2b += a2 * (s2 - s2b)
            let l = s1b, m = s2b - s1b, h = x - s2b
            total += x * x
            low += l * l
            mid += m * m
            high += h * h
        }
        lowStateA.store(s1.bitPattern, ordering: .relaxed)
        lowStateB.store(s1b.bitPattern, ordering: .relaxed)
        highStateA.store(s2.bitPattern, ordering: .relaxed)
        highStateB.store(s2b.bitPattern, ordering: .relaxed)
        let n = Float(samples.count)
        store(rms: (total / n).squareRoot(), low: (low / n).squareRoot(), mid: (mid / n).squareRoot(), high: (high / n).squareRoot())
    }

    /// A level with no band detail (all three bands read the same).
    func update(rms: Float) {
        store(rms: rms, low: rms, mid: rms, high: rms)
    }

    private func store(rms: Float, low: Float, mid: Float, high: Float) {
        dbBits.store(Self.decibels(rms).bitPattern, ordering: .relaxed)
        lowBits.store(Self.decibels(low).bitPattern, ordering: .relaxed)
        midBits.store(Self.decibels(mid).bitPattern, ordering: .relaxed)
        highBits.store(Self.decibels(high).bitPattern, ordering: .relaxed)
    }

    func reset() {
        let silent = LevelReading.floorDb.bitPattern
        dbBits.store(silent, ordering: .relaxed)
        lowBits.store(silent, ordering: .relaxed)
        midBits.store(silent, ordering: .relaxed)
        highBits.store(silent, ordering: .relaxed)
        lowStateA.store(0, ordering: .relaxed)
        lowStateB.store(0, ordering: .relaxed)
        highStateA.store(0, ordering: .relaxed)
        highStateB.store(0, ordering: .relaxed)
    }
}
