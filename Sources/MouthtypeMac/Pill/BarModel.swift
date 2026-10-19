import CoreGraphics
import Foundation

/// Level-to-meter maths for the pill, with no UI in it. The input is a level in dBFS (and three band levels). It is
/// mapped to a 0...1 fraction on a dB scale between a floor and a ceiling that follow the speaker and the room
/// slowly (`MeterAdapter`), with a soft knee near the top so loud input compresses instead of clipping flat. Ten
/// columns then read that level at slightly different delays (the middle newest, so speech ripples outward), scale
/// it by a fixed weight (tallest in the middle), lean on a different band each, and smooth it with a fast attack and
/// a release short enough to fall between words. The smoothed fractions are quantised to whole lit segments for the
/// segmented skin; the classic skin maps them straight to bar heights.
struct BarModel {
    static let barCount = 10
    /// Segments in each column, matching the skin's meter.
    static let segmentRows = 5

    /// Fixed per-column weights, 1 in the middle pair and lower toward the ends.
    static let weights: [Float] = {
        let raw = (0..<barCount).map { 0.3 + 0.7 * cos(Float.pi * abs(Float($0) - 4.5) / Float(barCount)) }
        let peak = raw.max() ?? 1
        return raw.map { $0 / peak }
    }()

    /// How late each column reads the level, in seconds: 18 ms a step out from the middle, 81 ms at the ends.
    static let delays: [TimeInterval] = (0..<barCount).map { abs(Double($0) - 4.5) * 0.018 }

    /// How much of its band's difference from the overall level a column takes, and the most it may move, in dB.
    static let bandLean: Float = 0.4
    static let bandReach: Float = 8

    static let attackTime: TimeInterval = 0.025
    /// Time constant of the fall in the middle columns; the outer ones are a little slower. A word gap of 100 to
    /// 300 ms takes a column to about a third and then under a tenth of its height.
    static let releaseTime: TimeInterval = 0.07
    static let releaseSpread: TimeInterval = 0.01
    /// Below this a column snaps to silence, so silence is exactly the baseline rather than a long tail.
    private static let settleFloor: Float = 0.002

    /// Where the soft knee starts, as a share of the span from floor to ceiling.
    static let kneeStart: Float = 0.75

    /// The fraction 0...1 for `db`: linear in dB from `floor` (0) up to the knee, then compressed toward 1, which a
    /// level at the ceiling reaches about 94% of and only well above it fully.
    static func fraction(db: Float, floor: Float, ceiling: Float) -> Float {
        guard db.isFinite, ceiling > floor else { return 0 }
        let x = (db - floor) / (ceiling - floor)
        guard x > 0 else { return 0 }
        guard x > kneeStart else { return x }
        return kneeStart + (1 - kneeStart) * tanh((x - kneeStart) / (1 - kneeStart))
    }

    private(set) var adapter = MeterAdapter()
    private var smoothed = [Float](repeating: 0, count: barCount)
    private var history: [(age: TimeInterval, reading: LevelReading)] = []

    /// Starts a recording over: the bars drop to rest. What the adapter has learned about the speaker and the room
    /// carries over.
    mutating func reset() {
        smoothed = [Float](repeating: 0, count: Self.barCount)
        history.removeAll()
    }

    /// Advances `dt` seconds with the current input and returns each column's smoothed fraction, 0...1.
    mutating func step(reading: LevelReading, dt: TimeInterval) -> [Float] {
        let dt = dt.isFinite ? max(0, dt) : 0
        let reading = Self.sanitized(reading)
        adapter.update(db: reading.db, dt: dt)

        for i in history.indices { history[i].age += dt }
        history.append((0, reading))
        history.removeAll { $0.age > (Self.delays.last ?? 0) + 0.05 }

        let floor = adapter.floorDb, ceiling = adapter.ceilingDb
        for i in 0..<Self.barCount {
            let seen = delayedReading(Self.delays[i])
            let target = Self.fraction(db: columnDb(i, seen), floor: floor, ceiling: ceiling) * Self.weights[i]
            let distance = abs(Double(i) - 4.5) - 0.5
            let tau = target > smoothed[i] ? Self.attackTime : Self.releaseTime + Self.releaseSpread * distance
            let alpha = Float(1 - exp(-dt / tau))
            smoothed[i] += (target - smoothed[i]) * alpha
            if smoothed[i] < Self.settleFloor, target == 0 { smoothed[i] = 0 }
        }
        return smoothed
    }

    private static func sanitized(_ r: LevelReading) -> LevelReading {
        func clean(_ v: Float) -> Float { v.isFinite ? min(0, max(LevelReading.floorDb, v)) : LevelReading.floorDb }
        return LevelReading(db: clean(r.db), low: clean(r.low), mid: clean(r.mid), high: clean(r.high))
    }

    /// Column `i` leans toward the low band at the left end, the mid band in the middle and the high band at the
    /// right end, so a vowel and an "s" don't look alike.
    private func columnDb(_ i: Int, _ r: LevelReading) -> Float {
        let p = Float(i) / Float(Self.barCount - 1)
        let band = p < 0.5 ? r.low + (r.mid - r.low) * (p * 2) : r.mid + (r.high - r.mid) * ((p - 0.5) * 2)
        let lean = min(0, max(-Self.bandReach, (band - r.db) * Self.bandLean))
        return r.db > LevelReading.floorDb ? r.db + lean : r.db
    }

    /// The reading as it was `delay` seconds ago: the newest sample at least that old, else the oldest we have.
    private func delayedReading(_ delay: TimeInterval) -> LevelReading {
        history.last(where: { $0.age >= delay })?.reading ?? history.first?.reading ?? .silence
    }

    /// Whole segments to light per column, 1...`segments`: the baseline segment is always lit, so silence is a
    /// single row, and a full column needs a fraction of 1.
    static func litSegments(_ fractions: [Float], segments: Int) -> [Int] {
        guard segments > 0 else { return fractions.map { _ in 0 } }
        return fractions.map { fraction in
            let f = fraction.isFinite ? min(1, max(0, fraction)) : 0
            return min(segments, max(1, Int((f * Float(segments) - 0.01).rounded(.up))))
        }
    }

    /// Processing: a three-column run of lit segments travelling back and forth along the row.
    static let processingStepsPerSecond = 12.0

    static func processingColumns(time: TimeInterval, columns: Int) -> ClosedRange<Int> {
        guard columns > 1 else { return 0...0 }
        let period = 2 * (columns - 1)
        let step = Int(max(0, time.isFinite ? time : 0) * processingStepsPerSecond) % period
        let centre = step < columns ? step : period - step
        return max(0, centre - 1)...min(columns - 1, centre + 1)
    }
}

/// The ceiling and floor of the dB scale, following the speaker and the room slowly so a quiet talker or a noisy
/// microphone still moves the bars, and neither silence nor a single shout moves them visibly.
///
/// The floor follows the noise floor, found as the lowest level of the last four to eight seconds. The ceiling
/// follows a slow estimate of how loud the speaker gets, updated only while there is speech, so silence cannot
/// raise the gain. Both are bounded.
struct MeterAdapter {
    /// At or below this the bars are at rest. The floor never goes lower, so a quiet room can't light them.
    static let floorLimits: ClosedRange<Float> = -55 ... -45
    /// Above the noise floor, so the noise itself reads as rest.
    static let noiseMargin: Float = 3
    static let noiseLimits: ClosedRange<Float> = -75 ... -42
    static let noiseWindow: TimeInterval = 4
    static let noiseRiseTime: TimeInterval = 2.5
    static let noiseFallTime: TimeInterval = 0.5

    /// Default full height is at -12 dBFS. The ceiling sits this far above the average level of speech.
    static let ceilingHeadroom: Float = 18
    static let ceilingLimits: ClosedRange<Float> = -30 ... -6
    static let loudStart: Float = -30
    static let loudRiseTime: TimeInterval = 5
    static let loudFallTime: TimeInterval = 2.5
    /// A level counts as speech this far above the floor.
    static let speechMargin: Float = 8
    /// The ceiling stays at least this far above the floor.
    static let minimumSpan: Float = 12

    private(set) var noiseDb: Float = -58
    private(set) var loudDb: Float = MeterAdapter.loudStart
    private var windowMin = Float.infinity
    private var previousWindowMin = Float.infinity
    private var windowAge: TimeInterval = 0

    var floorDb: Float {
        min(max(noiseDb + Self.noiseMargin, Self.floorLimits.lowerBound), Self.floorLimits.upperBound)
    }

    var ceilingDb: Float {
        max(floorDb + Self.minimumSpan, min(max(loudDb + Self.ceilingHeadroom, Self.ceilingLimits.lowerBound), Self.ceilingLimits.upperBound))
    }

    mutating func update(db: Float, dt: TimeInterval) {
        guard dt > 0 else { return }
        windowMin = min(windowMin, db)
        windowAge += dt
        if windowAge >= Self.noiseWindow {
            previousWindowMin = windowMin
            windowMin = .infinity
            windowAge = 0
        }
        let seen = min(windowMin, previousWindowMin)
        let target = min(Self.noiseLimits.upperBound, max(Self.noiseLimits.lowerBound, seen))
        let noiseTau = target < noiseDb ? Self.noiseFallTime : Self.noiseRiseTime
        noiseDb += (target - noiseDb) * Float(1 - exp(-dt / noiseTau))

        guard db > floorDb + Self.speechMargin else { return }
        let tau = db > loudDb ? Self.loudRiseTime : Self.loudFallTime
        loudDb += (db - loudDb) * Float(1 - exp(-dt / tau))
    }
}
