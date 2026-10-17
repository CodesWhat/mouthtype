import Foundation

public enum AudioRetentionAge: String, CaseIterable, Sendable {
    case days14, days30, days90, noAgeLimit

    public var seconds: TimeInterval? {
        switch self {
        case .days14: 14 * 86_400
        case .days30: 30 * 86_400
        case .days90: AudioArchive.defaultRetention
        case .noAgeLimit: nil
        }
    }
}

public enum AudioRetentionSize: String, CaseIterable, Sendable {
    case gb2, gb10

    public var bytes: Int {
        switch self {
        case .gb2: AudioArchive.defaultMaxTotalBytes
        case .gb10: 10 * 1_024 * 1_024 * 1_024
        }
    }
}

public struct AudioRetentionPolicy: Equatable, Sendable {
    public var age: AudioRetentionAge
    public var size: AudioRetentionSize

    public init(age: AudioRetentionAge = .days90, size: AudioRetentionSize = .gb2) {
        self.age = age
        self.size = size
    }

    public var maximumBytes: Int { size.bytes }
    public func expiration(from date: Date) -> Date? { age.seconds.map { date.addingTimeInterval($0) } }
    public func cutoff(at date: Date) -> Date { age.seconds.map { date.addingTimeInterval(-$0) } ?? .distantPast }
}
