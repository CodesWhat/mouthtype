import Foundation
import GRDB

public enum DictationStatus: String, Codable, Sendable, DatabaseValueConvertible {
    case started, recorded, transcribed, inserted, cancelled
    case tooShort = "too_short"
    case empty, failed
}

public enum DictationMode: String, Codable, Sendable {
    case hold
    case handsFree = "hands_free"
    case transform, command
}

public enum DictationTrigger: String, Codable, Sendable {
    case fn
    case fnSpace = "fn_space"
    case doubleTap = "double_tap"
    case pill, mouse, toggle
}

/// Where the text was headed. Surrounding field text is deliberately not part of this.
public struct DictationTarget: Sendable, Equatable {
    public var bundleID: String?
    public var appName: String?
    public var urlDomain: String?
    public var windowTitle: String?
    public var category: String?
    public var fieldRole: String?
    public var isSecure: Bool?

    public init(
        bundleID: String? = nil, appName: String? = nil, urlDomain: String? = nil, windowTitle: String? = nil,
        category: String? = nil, fieldRole: String? = nil, isSecure: Bool? = nil
    ) {
        self.bundleID = bundleID
        self.appName = appName
        self.urlDomain = urlDomain
        self.windowTitle = windowTitle
        self.category = category
        self.fieldRole = fieldRole
        self.isSecure = isSecure
    }
}

public struct DictationStart: Sendable {
    public var id: String
    public var startedAt: Date
    public var timeZone: TimeZone
    public var mode: DictationMode
    public var trigger: DictationTrigger
    public var target: DictationTarget
    public var retryOf: String?
    public var appVersion: String?
    public var osVersion: String?

    public init(
        id: String = UUID().uuidString, startedAt: Date = Date(), timeZone: TimeZone = .current,
        mode: DictationMode = .hold, trigger: DictationTrigger = .fn, target: DictationTarget = DictationTarget(),
        retryOf: String? = nil, appVersion: String? = nil, osVersion: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.timeZone = timeZone
        self.mode = mode
        self.trigger = trigger
        self.target = target
        self.retryOf = retryOf
        self.appVersion = appVersion
        self.osVersion = osVersion
    }
}

/// Timing (ms from key-down) and audio fields, written when the key comes up and the capture is in hand.
public struct CaptureRecord: Sendable {
    public var captureStartMs: Int?
    public var firstSampleMs: Int?
    public var firstNonzeroMs: Int?
    public var speechOnsetMs: Int?
    public var keyUpMs: Int?
    public var audioMs: Int?
    public var voicedMs: Int?
    public var audioPath: String?
    public var audioExpiresAt: Date?
    public var inputDeviceUID: String?
    public var inputDeviceName: String?
    public var inputTransport: String?
    public var sampleRateHz: Int?
    public var rmsDb: Double?
    public var peakDb: Double?
    public var noiseFloorDb: Double?

    public init(
        captureStartMs: Int? = nil, firstSampleMs: Int? = nil, firstNonzeroMs: Int? = nil, speechOnsetMs: Int? = nil,
        keyUpMs: Int? = nil, audioMs: Int? = nil, voicedMs: Int? = nil, audioPath: String? = nil,
        audioExpiresAt: Date? = nil, inputDeviceUID: String? = nil, inputDeviceName: String? = nil,
        inputTransport: String? = nil, sampleRateHz: Int? = nil, rmsDb: Double? = nil, peakDb: Double? = nil,
        noiseFloorDb: Double? = nil
    ) {
        self.captureStartMs = captureStartMs
        self.firstSampleMs = firstSampleMs
        self.firstNonzeroMs = firstNonzeroMs
        self.speechOnsetMs = speechOnsetMs
        self.keyUpMs = keyUpMs
        self.audioMs = audioMs
        self.voicedMs = voicedMs
        self.audioPath = audioPath
        self.audioExpiresAt = audioExpiresAt
        self.inputDeviceUID = inputDeviceUID
        self.inputDeviceName = inputDeviceName
        self.inputTransport = inputTransport
        self.sampleRateHz = sampleRateHz
        self.rmsDb = rmsDb
        self.peakDb = peakDb
        self.noiseFloorDb = noiseFloorDb
    }
}

public struct TranscriptionRecord: Sendable {
    public var transcription: Transcription
    public var rawText: String
    public var asrDoneMs: Int?
    /// Ms from key-down to the first word, known only once the engine has returned.
    public var speechOnsetMs: Int?
    public var language: String?
    public var boostTerms: [String]?

    public init(
        transcription: Transcription, rawText: String, asrDoneMs: Int? = nil, speechOnsetMs: Int? = nil,
        language: String? = nil, boostTerms: [String]? = nil
    ) {
        self.transcription = transcription
        self.rawText = rawText
        self.asrDoneMs = asrDoneMs
        self.speechOnsetMs = speechOnsetMs
        self.language = language
        self.boostTerms = boostTerms
    }
}

public struct CleanupRecord: Sendable {
    public var cleanerID: String?
    public var cleanerRev: String?
    public var level: String?
    public var style: String?
    public var ms: Int?
    public var outcome: String?  // skipped, ok, timeout, guard-rejected, failed
    public var promptSha: String?
    public var doneMs: Int?

    public init(
        cleanerID: String? = nil, cleanerRev: String? = nil, level: String? = nil, style: String? = nil,
        ms: Int? = nil, outcome: String? = nil, promptSha: String? = nil, doneMs: Int? = nil
    ) {
        self.cleanerID = cleanerID
        self.cleanerRev = cleanerRev
        self.level = level
        self.style = style
        self.ms = ms
        self.outcome = outcome
        self.promptSha = promptSha
        self.doneMs = doneMs
    }
}

public struct InsertionRecord: Sendable {
    public var finalText: String
    public var detText: String?
    public var cleanup: CleanupRecord?
    public var method: String?  // paste, typed, clipboard only, none
    public var outcome: String?  // confirmed, unknown, not landed, secure discard
    public var focusMoved: Bool?
    public var pasteReceiptMs: Int?
    public var insertDoneMs: Int?
    /// Where the text actually landed, when that differs from the start target. Replaces the row's target columns.
    public var target: DictationTarget?

    public init(
        finalText: String, detText: String? = nil, cleanup: CleanupRecord? = nil, method: String? = nil,
        outcome: String? = nil, focusMoved: Bool? = nil, pasteReceiptMs: Int? = nil, insertDoneMs: Int? = nil,
        target: DictationTarget? = nil
    ) {
        self.target = target
        self.finalText = finalText
        self.detText = detText
        self.cleanup = cleanup
        self.method = method
        self.outcome = outcome
        self.focusMoved = focusMoved
        self.pasteReceiptMs = pasteReceiptMs
        self.insertDoneMs = insertDoneMs
    }
}

public struct EditOp: Sendable, Equatable {
    public enum Kind: String, Sendable { case delete, replace, insert }

    public var stage: String  // filler, self-correction, spoken command, number format, dictionary, snippet, profanity, blend, llm
    public var kind: Kind
    public var fromText: String?
    public var toText: String?
    public var wordDelta: Int
    public var position: Int

    public init(stage: String, kind: Kind, fromText: String? = nil, toText: String? = nil, wordDelta: Int = 0, position: Int = 0) {
        self.stage = stage
        self.kind = kind
        self.fromText = fromText
        self.toText = toText
        self.wordDelta = wordDelta
        self.position = position
    }
}

public enum CorrectionKind: String, Sendable { case remember, forget }

/// One `correction` row: a spelling offered after a dictation, and how the user answered.
public struct CorrectionRecord: Sendable, Equatable {
    public var id: Int64
    public var dictationID: String
    public var kind: CorrectionKind
    public var heard: String
    public var corrected: String
    public var accepted: Bool?
    public var createdAt: Double
}

/// One `dictation` row as stored. Times are ms from key-down; `startedAt` and `audioExpiresAt` are unix seconds.
public struct DictationRecord: Codable, FetchableRecord, Sendable, Equatable {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase

    public var id: String
    public var startedAt: Double
    public var utcOffsetS: Int
    public var localDay: String
    public var mode: String
    public var trigger: String
    public var status: DictationStatus
    public var errorMessage: String?

    public var captureStartMs: Int?
    public var firstSampleMs: Int?
    public var firstNonzeroMs: Int?
    public var speechOnsetMs: Int?
    public var keyUpMs: Int?
    public var asrDoneMs: Int?
    public var cleanupDoneMs: Int?
    public var insertDoneMs: Int?

    public var audioMs: Int?
    public var voicedMs: Int?
    public var audioPath: String?
    public var audioExpiresAt: Double?
    public var inputDeviceUid: String?
    public var inputDeviceName: String?
    public var inputTransport: String?
    public var sampleRateHz: Int?
    public var rmsDb: Double?
    public var peakDb: Double?
    public var noiseFloorDb: Double?

    public var asrEngineId: String?
    public var asrModelRev: String?
    public var asrMs: Int?
    public var asrConfidence: Double?
    public var language: String?
    public var wordTimingsJson: String?
    public var boostTermsAppliedJson: String?

    public var rawText: String?
    public var detText: String?
    public var finalText: String?
    public var wordsRaw: Int?
    public var wordsFinal: Int?
    public var charsFinal: Int?

    public var cleanerId: String?
    public var cleanerRev: String?
    public var cleanupLevel: String?
    public var style: String?
    public var cleanupMs: Int?
    public var cleanupOutcome: String?
    public var promptSha: String?

    public var appBundleId: String?
    public var appName: String?
    public var urlDomain: String?
    public var windowTitle: String?
    public var category: String?
    public var fieldRole: String?
    public var isSecure: Bool?

    public var insertMethod: String?
    public var insertOutcome: String?
    public var focusMoved: Bool?
    public var pasteReceiptMs: Int?

    public var retryOf: String?
    public var appVersion: String?
    public var osVersion: String?

    public func wordTimings() throws -> [WordTiming] {
        guard let wordTimingsJson else { return [] }
        return try JSONDecoder().decode([WordTiming].self, from: Data(wordTimingsJson.utf8))
    }
}

/// The columns the take lists read (Home, Suggestions, the menu, kept-audio lookup), without the heavy ones such as
/// `word_timings_json`. `TranscriptStore.dictation(id:)` still returns the full `DictationRecord`.
public struct TakeRecord: Codable, FetchableRecord, Sendable, Equatable {
    public static let databaseColumnDecodingStrategy = DatabaseColumnDecodingStrategy.convertFromSnakeCase
    static let columns = "id, started_at, audio_path, boost_terms_applied_json, raw_text, final_text, app_name, is_secure"

    public var id: String
    public var startedAt: Double
    public var audioPath: String?
    public var boostTermsAppliedJson: String?
    public var rawText: String?
    public var finalText: String?
    public var appName: String?
    public var isSecure: Bool?
}

public struct StatsSummary: Equatable, Sendable {
    public var wordsToday: Int
    public var recentWPM: Double
    public var currentStreakDays: Int
    public var longestStreakDays: Int

    public init(wordsToday: Int, recentWPM: Double, currentStreakDays: Int, longestStreakDays: Int) {
        self.wordsToday = wordsToday
        self.recentWPM = recentWPM
        self.currentStreakDays = currentStreakDays
        self.longestStreakDays = longestStreakDays
    }
}
