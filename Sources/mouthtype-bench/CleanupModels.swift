import Foundation
import MouthtypeCore

struct CaseRun: Codable {
    var id: String
    var output: String
    var error: String?
    var firstOutputMs: [Double]
    var totalMs: [Double]
    var outputTokens: Int?
    var tokensPerSecond: Double?
}

struct CleanupWorkerOutput: Codable {
    var cleanerID: String
    var displayName: String
    var prepare: PrepareTimings?
    var peakFootprintBytes: Int
    var firstCleanMs: Double?
    var modelBytes: Int?
    var modelPath: String?
    var timingsRepresentative: Bool
    var usesSharedPrompt: Bool
    var license: String?
    var cases: [CaseRun]
    var unavailable: String?
    var error: String?
}

struct BucketTiming: Codable {
    var samples: Int
    var firstMedianMs: Double
    var firstP95Ms: Double
    var totalMedianMs: Double
    var totalP95Ms: Double
}

struct CaseFailure: Codable {
    var caseID: String
    var category: String
    var input: String
    var output: String
    var reasons: [String]
}

struct JudgeSummary: Codable {
    /// Mean rubric total out of 8 across all cases.
    var meanScore: Double
    var graded: Int
    var missing: Int
}

struct CleanerReport: Codable {
    var cleanerID: String
    var displayName: String
    /// "ok", "unavailable" or "failed".
    var status: String
    var statusDetail: String?
    var cold: CleanupWorkerOutput?
    var warm: CleanupWorkerOutput?
    var timingsComparable: Bool
    var buckets: [String: BucketTiming]
    var tokensPerSecondMedian: Double?
    var passRate: Double?
    var categoryPassRates: [String: Double]
    var failures: [CaseFailure]
    var judge: JudgeSummary?
}

struct JudgeStatus: Codable {
    var requested: Bool
    var ran: Bool
    var model: String
    var note: String?
}

struct CleanupBenchReport: Codable {
    var date: String
    var machine: MachineInfo
    var runsPerCase: Int
    var caseCount: Int
    var categories: [String: Int]
    var judge: JudgeStatus
    var parakeetShortMs: Double?
    var cleaners: [CleanerReport]
}
