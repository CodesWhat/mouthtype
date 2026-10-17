import Foundation

/// 16 kHz mono 16-bit PCM WAV files at `<support dir>/audio/<dictation id>.wav`.
public struct AudioArchive: Sendable {
    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var byteSize: Int
    }

    public enum ArchiveError: Error, Equatable {
        case notWav
    }

    /// Balanced preset: 90 days or 2 GB, whichever hits first.
    public static let defaultRetention: TimeInterval = 90 * 24 * 3600
    public static let defaultMaxTotalBytes = 2 * 1024 * 1024 * 1024
    public static let sampleRate = 16_000

    public let directory: URL

    public init(supportDirectory: URL) {
        directory = supportDirectory.appendingPathComponent("audio", isDirectory: true)
    }

    public func url(for id: String) -> URL {
        directory.appendingPathComponent("\(id).wav")
    }

    /// The in-progress copy of a recording that has not ended yet.
    public func partialURL(for id: String) -> URL {
        directory.appendingPathComponent("\(id).partial.wav")
    }

    /// Writes the finished recording, then drops its in-progress copy.
    @discardableResult
    public func write(samples: [Float], id: String) throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Self.wavData(samples: samples)
        let url = url(for: id)
        try data.write(to: url, options: .atomic)
        discardPartial(id: id)
        return Entry(url: url, byteSize: data.count)
    }

    /// Adds the next stretch of a recording in progress to `<id>.partial.wav`. The header claims the largest size a
    /// WAV can, so the file reads back as far as it got if the app dies mid-recording.
    public func appendPartial(samples: [Float], id: String) throws {
        guard !samples.isEmpty else { return }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = partialURL(for: id)
        if !FileManager.default.fileExists(atPath: url.path) {
            try Self.header(riffSize: .max, dataSize: .max).write(to: url, options: .atomic)
        }
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Self.pcm(samples))
    }

    public func discardPartial(id: String) {
        try? FileManager.default.removeItem(at: partialURL(for: id))
    }

    /// The samples of a WAV at `url`, cut at the end of the file when its header claims more.
    public static func read(contentsOf url: URL) throws -> [Float] {
        try samples(fromWAV: Data(contentsOf: url))
    }

    public func read(id: String) throws -> [Float] {
        try Self.samples(fromWAV: Data(contentsOf: url(for: id)))
    }

    /// Deletes files older than `cutoff`, then the oldest of the rest until the total fits `maxTotalBytes`.
    /// When supplied, only `eligibleIDs` are counted or removed; crash partials are always excluded.
    /// Returns the ids removed so the caller can null `audio_path`.
    public func purge(olderThan cutoff: Date, maxTotalBytes: Int = defaultMaxTotalBytes, eligibleIDs: Set<String>? = nil) throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files: [(id: String, url: URL, date: Date, size: Int)] = []
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys)
        where url.pathExtension == "wav" && !url.lastPathComponent.hasSuffix(".partial.wav") {
            let id = url.deletingPathExtension().lastPathComponent
            guard eligibleIDs?.contains(id) != false else { continue }
            let values = try url.resourceValues(forKeys: Set(keys))
            files.append((id, url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
        }
        files.sort { $0.date < $1.date }

        var removed: [String] = []
        var total = files.reduce(0) { $0 + $1.size }
        for file in files where file.date < cutoff || total > maxTotalBytes {
            try manager.removeItem(at: file.url)
            removed.append(file.id)
            total -= file.size
        }
        return removed
    }

    static func wavData(samples: [Float]) -> Data {
        let dataSize = UInt32(samples.count * 2)
        var data = header(riffSize: 36 + dataSize, dataSize: dataSize)
        data.append(pcm(samples))
        return data
    }

    private static func header(riffSize: UInt32, dataSize: UInt32) -> Data {
        var data = Data(capacity: 44)
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(riffSize))
        data.append(contentsOf: Array("WAVEfmt ".utf8))
        data.append(le32(16))
        data.append(le16(1))                            // PCM
        data.append(le16(1))                            // mono
        data.append(le32(UInt32(sampleRate)))
        data.append(le32(UInt32(sampleRate * 2)))       // byte rate
        data.append(le16(2))                            // block align
        data.append(le16(16))                           // bits per sample
        data.append(contentsOf: Array("data".utf8))
        data.append(le32(dataSize))
        return data
    }

    private static func pcm(_ samples: [Float]) -> Data {
        var data = Data(capacity: samples.count * 2)
        for s in samples {
            let clamped = max(-1, min(1, s))
            data.append(le16(UInt16(bitPattern: Int16(clamped * 32767))))
        }
        return data
    }

    static func samples(fromWAV data: Data) throws -> [Float] {
        let bytes = [UInt8](data)
        guard bytes.count >= 12, bytes[0..<4] == Array("RIFF".utf8)[...], bytes[8..<12] == Array("WAVE".utf8)[...] else {
            throw ArchiveError.notWav
        }
        var offset = 12
        while offset + 8 <= bytes.count {
            let size = Int(bytes[offset + 4]) | Int(bytes[offset + 5]) << 8 | Int(bytes[offset + 6]) << 16 | Int(bytes[offset + 7]) << 24
            let body = offset + 8
            if bytes[offset..<offset + 4] == Array("data".utf8)[...] {
                let end = min(bytes.count, body + size)
                var out: [Float] = []
                out.reserveCapacity((end - body) / 2)
                var i = body
                while i + 1 < end {
                    out.append(Float(Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)) / 32767)
                    i += 2
                }
                return out
            }
            offset = body + size + (size & 1)
        }
        throw ArchiveError.notWav
    }

    private static func le32(_ v: UInt32) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 4)
    }

    private static func le16(_ v: UInt16) -> Data {
        var x = v.littleEndian
        return Data(bytes: &x, count: 2)
    }
}
