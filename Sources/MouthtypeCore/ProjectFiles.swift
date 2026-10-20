import Foundation

/// The git-tracked file names of the project in front, for editor hints. Tracked files only, so ignored secrets
/// files are never listed. Paths are held in memory and cached by repository root; nothing is written or logged.
public enum ProjectFiles {
    /// Most paths one listing returns, and most bytes read from git.
    public static let maxPaths = 5_000
    public static let maxBytes = 1_000_000

    /// The nearest directory at or above `directory` that holds a `.git` entry (a folder, or a file for a worktree).
    public static func repositoryRoot(containing directory: URL) -> URL? {
        var url = directory.standardizedFileURL
        for _ in 0..<40 {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent(".git").path) { return url }
            let parent = url.deletingLastPathComponent()
            if parent.path == url.path { return nil }
            url = parent
        }
        return nil
    }

    /// Tracked paths relative to `root`, capped. Empty when git is missing, fails, or `root` isn't a repository.
    public static func trackedFiles(in root: URL) async -> [String] {
        let key = root.standardizedFileURL.path
        let stamp = indexStamp(root)
        if let hit = cache.get(key, stamp: stamp) { return hit }
        guard let paths = await run(root: root) else { return [] }
        cache.set(key, stamp: stamp, paths: paths)
        return paths
    }

    /// Drops every cached listing. For tests.
    static func resetCache() { cache.reset() }

    private static func indexStamp(_ root: URL) -> Date? {
        var gitDir = root.appendingPathComponent(".git")
        if let text = try? String(contentsOf: gitDir, encoding: .utf8), text.hasPrefix("gitdir:") {
            let path = text.dropFirst(7).trimmingCharacters(in: .whitespacesAndNewlines)
            gitDir = URL(fileURLWithPath: path, relativeTo: root)
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: gitDir.appendingPathComponent("index").path)
        return attributes?[.modificationDate] as? Date
    }

    /// Never `/usr/bin/git`: without developer tools it is a stub that opens an install prompt.
    static func gitExecutable() -> String? {
        [
            "/opt/homebrew/bin/git", "/usr/local/bin/git", "/Library/Developer/CommandLineTools/usr/bin/git",
            "/Applications/Xcode.app/Contents/Developer/usr/bin/git",
        ].first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func run(root: URL) async -> [String]? {
        guard let git = gitExecutable() else { return nil }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: git)
        process.arguments = ["-C", root.path, "ls-files", "-z"]
        process.environment = ["GIT_OPTIONAL_LOCKS": "0", "PATH": "/usr/bin:/bin"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let handle = Handle(process)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<[String]?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    guard !handle.cancelled, (try? process.run()) != nil else { return continuation.resume(returning: nil) }
                    var data = Data()
                    var truncated = false
                    while let chunk = try? pipe.fileHandleForReading.read(upToCount: 64 * 1024), !chunk.isEmpty {
                        data.append(chunk)
                        if data.count >= maxBytes {
                            truncated = true
                            process.terminate()
                            break
                        }
                    }
                    process.waitUntilExit()
                    guard truncated || process.terminationStatus == 0 else { return continuation.resume(returning: nil) }
                    var paths = data.split(separator: 0).map { String(decoding: $0, as: UTF8.self) }
                    // The last entry of a cut-off listing may be half a path.
                    if truncated { paths.removeLast(min(1, paths.count)) }
                    continuation.resume(returning: Array(paths.prefix(maxPaths)))
                }
            }
        } onCancel: {
            handle.cancel()
        }
    }

    private final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private let process: Process
        private var flagged = false
        init(_ process: Process) { self.process = process }
        var cancelled: Bool { lock.withLock { flagged } }
        func cancel() {
            lock.withLock { flagged = true }
            if process.isRunning { process.terminate() }
        }
    }

    private static let cache = Cache()

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (stamp: Date?, paths: [String])] = [:]
        private var order: [String] = []
        private let limit = 8

        func get(_ key: String, stamp: Date?) -> [String]? {
            lock.withLock {
                guard let stamp, let entry = entries[key], entry.stamp == stamp else { return nil }
                return entry.paths
            }
        }

        func set(_ key: String, stamp: Date?, paths: [String]) {
            lock.withLock {
                if entries[key] == nil { order.append(key) }
                entries[key] = (stamp, paths)
                while order.count > limit { entries[order.removeFirst()] = nil }
            }
        }

        func reset() { lock.withLock { entries = [:]; order = [] } }
    }
}
