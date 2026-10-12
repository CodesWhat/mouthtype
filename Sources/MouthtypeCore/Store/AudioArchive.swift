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

    @discardableResult
    public func write(samples: [Float], id: String) throws -> Entry {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = Self.wavData(samples: samples)
        let url = url(for: id)
        try data.write(to: url, options: .atomic)
        return Entry(url: url, byteSize: data.count)
    }

    public func read(id: String) throws -> [Float] {
        try Self.samples(fromWAV: Data(contentsOf: url(for: id)))
    }

    /// Deletes files older than `cutoff`, then the oldest of the rest until the total fits `maxTotalBytes`.
    /// Returns the ids removed so the caller can null `audio_path`.
    public func purge(olderThan cutoff: Date, maxTotalBytes: Int = defaultMaxTotalBytes) throws -> [String] {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return [] }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        var files: [(id: String, url: URL, date: Date, size: Int)] = []
        for url in try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: keys) where url.pathExtension == "wav" {
            let values = try url.resourceValues(forKeys: Set(keys))
            files.append((url.deletingPathExtension().lastPathComponent, url, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0))
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
        var data = Data(capacity: 44 + Int(dataSize))
        data.append(contentsOf: Array("RIFF".utf8))
        data.append(le32(36 + dataSize))
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
