import Foundation

/// How far a model download has got, from whichever library is doing it. Bytes are real when the library reports them
/// (Hugging Face) and estimated from a known total when it reports only a fraction (FluidAudio). When neither is usable,
/// file counts carry the bar.
public struct ModelDownloadProgress: Sendable, Equatable {
    public var completedBytes: Int64
    /// 0 when the total isn't known.
    public var totalBytes: Int64
    public var completedFiles: Int
    /// 0 when the count isn't known.
    public var totalFiles: Int
    /// Smoothed estimate, nil until the rate has settled.
    public var secondsRemaining: Double?

    public init(completedBytes: Int64 = 0, totalBytes: Int64 = 0, completedFiles: Int = 0, totalFiles: Int = 0, secondsRemaining: Double? = nil) {
        self.completedBytes = completedBytes
        self.totalBytes = totalBytes
        self.completedFiles = completedFiles
        self.totalFiles = totalFiles
        self.secondsRemaining = secondsRemaining
    }

    /// A fraction against a total the catalog knows. The byte count is the fraction of that total, so it is an estimate.
    public init(fraction: Double, knownTotalBytes: Int64 = 0) {
        let clamped = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        self.init(completedBytes: Int64((Double(knownTotalBytes) * clamped).rounded()), totalBytes: knownTotalBytes)
        if knownTotalBytes == 0 { fractionOnly = clamped }
    }

    /// Hugging Face snapshot progress. Units are bytes when the repo tree declared file sizes. When it didn't, every file
    /// weighs one unit, so the units are file counts and the known total from the catalog gives the bar its size.
    public init(hubCompletedUnits: Int64, hubTotalUnits: Int64, knownTotalBytes: Int64 = 0) {
        if hubTotalUnits >= Self.byteUnitThreshold {
            self.init(completedBytes: min(max(hubCompletedUnits, 0), hubTotalUnits), totalBytes: hubTotalUnits)
        } else {
            let total = max(Int(hubTotalUnits), 0)
            let done = min(max(Int(hubCompletedUnits), 0), total)
            let fraction = total > 0 ? Double(done) / Double(total) : 0
            self.init(completedBytes: Int64((Double(knownTotalBytes) * fraction).rounded()), totalBytes: 0, completedFiles: done, totalFiles: total)
            estimatedBytes = knownTotalBytes
        }
    }

    /// Below this many units a hub total can't be a byte count (a single megabyte is already a million).
    static let byteUnitThreshold: Int64 = 1_000_000

    private var fractionOnly: Double?
    private var estimatedBytes: Int64?

    /// Bytes behind the bar come from a measured total.
    public var usesBytes: Bool { totalBytes > 0 }

    /// The total to show next to the bar: measured, else the catalog's.
    public var displayTotalBytes: Int64 { totalBytes > 0 ? totalBytes : (estimatedBytes ?? 0) }

    public var fraction: Double {
        if totalBytes > 0 { return min(max(Double(completedBytes) / Double(totalBytes), 0), 1) }
        if totalFiles > 0 { return min(max(Double(completedFiles) / Double(totalFiles), 0), 1) }
        return fractionOnly ?? 0
    }
}

/// What a model row or step shows: not fetched, fetching, on disk and finishing up, ready, or broken.
public enum ModelDownloadStatus: Sendable, Equatable {
    case available
    case downloading(ModelDownloadProgress)
    /// Waiting on the first report, or loading with nothing to show yet.
    case preparing
    case done
    case failed(message: String)

    public var fraction: Double {
        switch self {
        case let .downloading(progress): progress.fraction
        case .done: 1
        default: 0
        }
    }
}

/// Smooths the download rate over the last few seconds so the time remaining doesn't jump with every burst.
public struct DownloadRateMeter: Sendable, Equatable {
    public var window: TimeInterval
    /// The least time the window must span before an estimate is given.
    public var minimumSpan: TimeInterval
    private var samples: [(time: TimeInterval, fraction: Double)] = []

    public init(window: TimeInterval = 6, minimumSpan: TimeInterval = 1.5) {
        self.window = window
        self.minimumSpan = minimumSpan
    }

    public static func == (lhs: DownloadRateMeter, rhs: DownloadRateMeter) -> Bool {
        lhs.window == rhs.window && lhs.minimumSpan == rhs.minimumSpan
            && lhs.samples.map(\.time) == rhs.samples.map(\.time) && lhs.samples.map(\.fraction) == rhs.samples.map(\.fraction)
    }

    public mutating func reset() { samples.removeAll() }

    /// A fraction that goes backwards is ignored, so a restarted stage can't read as negative speed.
    public mutating func record(fraction: Double, at time: TimeInterval) {
        let value = min(max(fraction.isFinite ? fraction : 0, 0), 1)
        if let last = samples.last, value < last.fraction || time < last.time { return }
        samples.append((time, value))
        samples.removeAll { time - $0.time > window }
    }

    /// Fraction per second across the window, nil until it spans `minimumSpan` and has moved.
    public var fractionPerSecond: Double? {
        guard let first = samples.first, let last = samples.last, last.time - first.time >= minimumSpan else { return nil }
        let rate = (last.fraction - first.fraction) / (last.time - first.time)
        return rate > 0 ? rate : nil
    }

    public var secondsRemaining: Double? {
        guard let last = samples.last, let rate = fractionPerSecond else { return nil }
        return max(0, (1 - last.fraction) / rate)
    }
}

/// Turns FluidAudio's per-model reports into one monotonic byte count. FluidAudio makes one loadModels call per Parakeet
/// model, each reporting its own 0...1 (download in the first half, compile in the second), so the raw fraction restarts at
/// every call. The first call downloads the whole repo, so its download half is scaled against the full total, and the
/// bar holds there once it finishes.
public struct StagedDownloadTracker: Sendable, Equatable {
    public enum Event: Sendable, Equatable {
        case listing
        case downloading
        case compiling
        /// The model finished: FluidAudio reports 1.0 with an empty model name.
        case finished
    }

    public let stageBytes: [Int64]
    /// Share of each model's own 0...1 that is download. The rest is compile.
    public let downloadWeight: Double
    public private(set) var stage = 0
    private var highWater: Double = 0

    public init(stageBytes: [Int64], downloadWeight: Double = 0.5) {
        self.stageBytes = stageBytes
        self.downloadWeight = downloadWeight
    }

    public var totalBytes: Int64 { stageBytes.reduce(0, +) }

    /// True once every model has finished.
    public var isComplete: Bool { stage >= stageBytes.count }

    public var initial: ModelDownloadProgress {
        ModelDownloadProgress(completedBytes: 0, totalBytes: totalBytes, completedFiles: 0, totalFiles: stageBytes.count)
    }

    public mutating func update(fraction: Double, event: Event) -> ModelDownloadProgress {
        let within: Double
        switch event {
        case .listing: within = 0
        case .downloading: within = min(max((fraction.isFinite ? fraction : 0) / downloadWeight, 0), 1)
        case .compiling, .finished: within = 1
        }
        // FluidAudio's first loadModels call downloads the whole repo (allModelsExist checks every required model), so
        // its download fraction spans the full total. Later models only report cached, compiling and finished.
        let done = stage >= 1 ? Double(totalBytes) : Double(totalBytes) * within
        highWater = max(highWater, done)
        if event == .finished, stage < stageBytes.count { stage += 1 }
        return ModelDownloadProgress(completedBytes: Int64(highWater.rounded()), totalBytes: totalBytes, completedFiles: stage, totalFiles: stageBytes.count)
    }
}

public enum ModelDownloadFormat {
    /// "483 MB" or "5.2 GB", decimal units like the rest of the app.
    public static func size(_ bytes: Int64) -> String {
        bytes >= 1_000_000_000 ? String(format: "%.1f GB", Double(bytes) / 1e9) : "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }

    public static func remaining(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "" }
        if seconds < 10 { return "a few seconds left" }
        if seconds < 60 { return "about \(Int((seconds / 5).rounded()) * 5) seconds left" }
        let minutes = Int((seconds / 60).rounded(.up))
        if minutes < 60 { return "about \(minutes) min left" }
        let rounded = Int((Double(minutes) / 5).rounded()) * 5
        let (hours, rest) = (rounded / 60, rounded % 60)
        return rest == 0 ? "about \(hours) hr left" : "about \(hours) hr \(rest) min left"
    }

    /// "123 of 483 MB, about 2 min left". File counts stand in when no byte total is known.
    public static func caption(_ progress: ModelDownloadProgress) -> String {
        var parts: [String] = []
        let total = progress.displayTotalBytes
        if total > 0 {
            let completed = progress.completedBytes
            if total >= 1_000_000_000 {
                parts.append(String(format: "%.1f of %.1f GB", Double(completed) / 1e9, Double(total) / 1e9))
            } else {
                parts.append("\(Int((Double(completed) / 1e6).rounded())) of \(Int((Double(total) / 1e6).rounded())) MB")
            }
        } else if progress.totalFiles > 0 {
            parts.append("\(progress.completedFiles) of \(progress.totalFiles) files")
        } else {
            parts.append("\(Int((progress.fraction * 100).rounded()))%")
        }
        if let seconds = progress.secondsRemaining { parts.append(remaining(seconds)) }
        return parts.joined(separator: ", ")
    }
}
