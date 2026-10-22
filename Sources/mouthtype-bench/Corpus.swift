import Foundation
import MouthtypeCore

struct CorpusClip {
    let name: String
    let audioURL: URL
    let reference: String
}

enum CorpusError: Error, LocalizedError {
    case empty(String)
    case commandFailed(String)
    case fetchFailed(String)

    var errorDescription: String? {
        switch self {
        case let .empty(path): return "No audio clips with matching .txt references in \(path)"
        case let .commandFailed(message): return message
        case let .fetchFailed(message): return message
        }
    }
}

enum Corpus {
    static let defaultDirectory = "bench-cache/corpus"
    static let audioExtensions: Set<String> = ["wav", "m4a", "aiff", "aif", "caf", "flac"]

    static let syntheticTexts: [(name: String, text: String)] = [
        (
            "synthetic-1-slack-2s",
            "Sounds good, I'll send it over now."
        ),
        (
            "synthetic-2-slack-5s",
            "Hey, can you check the staging deploy before the meeting? The health check looks off."
        ),
        (
            "synthetic-3-review-10s",
            "In this pull request, the OAuth callback swallows errors from the Kubernetes API client. "
                + "Please log the failure and return a proper status code."
        ),
        (
            "synthetic-4-email-20s",
            "Hi Dana, thanks for sending over the revised proposal. I went through the timeline and the budget "
                + "with the team this morning, and we're mostly aligned. The one open question is the rollout plan "
                + "for the second quarter, specifically whether we can stage the migration by region instead of "
                + "cutting everything over in a single weekend."
        ),
        (
            "synthetic-5-email-45s",
            "Hi everyone, quick update on where the migration stands. The database cutover finished last night "
                + "without any downtime, and the read replicas are already caught up. Over the next few days I want "
                + "to focus on three things. First, we need to rotate the OAuth client secrets, since the old ones "
                + "were shared in a few places they shouldn't have been. Second, the Kubernetes manifests for the "
                + "worker pool still point at the old cluster, so I'll open a pull request to fix that and tag "
                + "the platform team for review. Third, the dashboards need new alerts, because the latency "
                + "thresholds we set last quarter don't match what we're seeing now. If anyone has concerns about "
                + "the schedule, please say so in the thread before Friday, and I'll adjust the plan."
        ),
    ]

    static func load(directory: URL) throws -> [CorpusClip] {
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        let clips: [CorpusClip] =
            files
            .filter { audioExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .compactMap { audio in
                let textURL = audio.deletingPathExtension().appendingPathExtension("txt")
                guard let reference = try? String(contentsOf: textURL, encoding: .utf8) else { return nil }
                return CorpusClip(
                    name: audio.deletingPathExtension().lastPathComponent,
                    audioURL: audio,
                    reference: reference.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            }
        guard !clips.isEmpty else { throw CorpusError.empty(directory.path) }
        return clips
    }

    /// Builds the default corpus into `directory`. Returns false when the real-speech set could not be fetched.
    @discardableResult
    static func build(into directory: URL) async throws -> Bool {
        let fm = FileManager.default
        let staging = directory.deletingLastPathComponent().appendingPathComponent("corpus.partial", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)

        for item in syntheticTexts {
            let audio = staging.appendingPathComponent("\(item.name).aiff")
            try runSay(text: item.text, output: audio)
            try item.text.write(to: staging.appendingPathComponent("\(item.name).txt"), atomically: true, encoding: .utf8)
        }

        var realFetched = true
        do {
            try await fetchLibriSpeech(count: 10, into: staging)
        } catch {
            realFetched = false
            FileHandle.standardError.write(
                Data(
                    """
                    WARNING: could not fetch real speech from LibriSpeech (\(error.localizedDescription)).
                    WARNING: the corpus is SYNTHETIC ONLY. TTS audio flatters WER, so do not judge accuracy from it.

                    """.utf8))
            for file in (try? fm.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil)) ?? []
            where file.lastPathComponent.hasPrefix("real-") {
                try? fm.removeItem(at: file)
            }
        }

        try? fm.removeItem(at: directory)
        try fm.createDirectory(at: directory.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: staging, to: directory)
        return realFetched
    }

    private static func runSay(text: String, output: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/say")
        process.arguments = ["-o", output.path, text]
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw CorpusError.commandFailed("say exited with status \(process.terminationStatus)")
        }
    }

    private struct RowsResponse: Decodable {
        struct Row: Decodable {
            struct Payload: Decodable {
                struct Audio: Decodable { let src: URL }
                let audio: [Audio]
                let text: String
                let id: String
            }
            let row: Payload
        }
        let rows: [Row]
    }

    static let librispeechRowsURL =
        "https://datasets-server.huggingface.co/rows?dataset=openslr/librispeech_asr&config=clean&split=test&offset=0&length=%d"

    private static func fetchLibriSpeech(count: Int, into directory: URL) async throws {
        guard let url = URL(string: String(format: librispeechRowsURL, count)) else {
            throw CorpusError.fetchFailed("bad rows URL")
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw CorpusError.fetchFailed("rows endpoint returned HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)")
        }
        let rows = try JSONDecoder().decode(RowsResponse.self, from: data).rows
        guard rows.count == count else {
            throw CorpusError.fetchFailed("expected \(count) rows, got \(rows.count)")
        }
        for row in rows {
            guard let src = row.row.audio.first?.src else { throw CorpusError.fetchFailed("row \(row.row.id) has no audio") }
            let (audio, audioResponse) = try await URLSession.shared.data(from: src)
            guard (audioResponse as? HTTPURLResponse)?.statusCode == 200, !audio.isEmpty else {
                throw CorpusError.fetchFailed("audio download failed for \(row.row.id)")
            }
            let name = "real-\(row.row.id)"
            try audio.write(to: directory.appendingPathComponent("\(name).flac"))
            try row.row.text.write(to: directory.appendingPathComponent("\(name).txt"), atomically: true, encoding: .utf8)
        }
    }
}
