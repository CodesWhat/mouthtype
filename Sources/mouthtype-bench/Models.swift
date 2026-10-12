import Foundation
import MouthtypeCore

enum ClipSet: String, Codable, CaseIterable {
    case synthetic
    case real
    case custom

    init(clipName: String) {
        let prefix = clipName.split(separator: "-").first.map(String.init) ?? ""
        self = ClipSet(rawValue: prefix) ?? .custom
    }
}

struct ClipResult: Codable {
    var name: String
    var set: ClipSet
    var audioSeconds: Double
    var latenciesMs: [Double]
    var medianMs: Double
    var p95Ms: Double
    var rtfx: Double
    var reference: String
    var hypothesis: String
    var edits: Int
    var referenceWords: Int
}

struct WorkerOutput: Codable {
    var engineID: String
    var displayName: String
    var prepare: PrepareTimings?
    var peakRSSBytes: Int
    var firstTranscribeMs: Double?
    var modelBytes: Int?
    var modelPath: String?
    var clips: [ClipResult]
    var error: String?
}

struct EngineReport: Codable {
    var engineID: String
    var displayName: String
    var cold: WorkerOutput?
    var warm: WorkerOutput?
    var error: String?
    var shortClipMedianMs: Double?
    var overallRTFx: Double?
    var werSynthetic: Double?
    var werReal: Double?
    var werCustom: Double?
}

struct MachineInfo: Codable {
    var chip: String
    var ramGB: Int
    var macOS: String
    var swift: String
    var packageVersions: [String: String]
}

struct BenchReport: Codable {
    var date: String
    var machine: MachineInfo
    var corpus: String
    var runsPerClip: Int
    var warmupRuns: Int
    var hasRealSpeech: Bool
    var engines: [EngineReport]
}
