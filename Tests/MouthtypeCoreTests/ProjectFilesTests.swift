import Foundation
import Testing
@testable import MouthtypeCore

@Suite(.serialized) struct ProjectFilesTests {
    private func makeRepo() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("project-files-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources/Deep"), withIntermediateDirectories: true)
        try "x".write(to: root.appendingPathComponent("TopLevelThing.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("Sources/Deep/NestedHelperKit.swift"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent("SecretsIgnored.env"), atomically: true, encoding: .utf8)
        try "SecretsIgnored.env\n".write(to: root.appendingPathComponent(".gitignore"), atomically: true, encoding: .utf8)
        return root
    }

    private func git(_ root: URL, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ProjectFiles.gitExecutable() ?? "/usr/bin/git")
        process.arguments = ["-C", root.path, "-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
    }

    @Test func cwdInsideARepoResolvesToItsRoot() throws {
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
        let nested = root.appendingPathComponent("Sources/Deep")
        #expect(ProjectFiles.repositoryRoot(containing: nested)?.standardizedFileURL.path == root.standardizedFileURL.path)
        #expect(ProjectFiles.repositoryRoot(containing: root)?.standardizedFileURL.path == root.standardizedFileURL.path)
    }

    @Test func aDirectoryOutsideAnyRepoResolvesToNothing() throws {
        let loose = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loose) }
        // The temp directory sits under no repository on a normal machine.
        #expect(ProjectFiles.repositoryRoot(containing: loose) == nil)
    }

    @Test(.enabled(if: ProjectFiles.gitExecutable() != nil)) func listsTrackedFilesOnly() async throws {
        ProjectFiles.resetCache()
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, ["init", "-q"])
        try git(root, ["add", "-A"])
        let files = await ProjectFiles.trackedFiles(in: root)
        #expect(Set(files) == [".gitignore", "TopLevelThing.swift", "Sources/Deep/NestedHelperKit.swift"])
        #expect(!files.contains("SecretsIgnored.env"))
        let names = EditorHints.terms(cursor: [], title: [], files: EditorHints.nameCandidates(fromPaths: files)).map(\.text)
        #expect(names == ["TopLevelThing", "NestedHelperKit"])
    }

    @Test(.enabled(if: ProjectFiles.gitExecutable() != nil)) func cachesByRootUntilTheIndexChanges() async throws {
        ProjectFiles.resetCache()
        let root = try makeRepo()
        defer { try? FileManager.default.removeItem(at: root) }
        try git(root, ["init", "-q"])
        try git(root, ["add", "-A"])
        let first = await ProjectFiles.trackedFiles(in: root)
        try "x".write(to: root.appendingPathComponent("LateAddition.swift"), atomically: true, encoding: .utf8)
        // Untracked, and the index is untouched, so this is served from the cache.
        #expect(await ProjectFiles.trackedFiles(in: root) == first)
        try await Task.sleep(for: .milliseconds(1_100))
        try git(root, ["add", "LateAddition.swift"])
        #expect(await ProjectFiles.trackedFiles(in: root).contains("LateAddition.swift"))
    }

    @Test func aFolderThatIsNotARepositoryListsNothing() async throws {
        ProjectFiles.resetCache()
        let loose = FileManager.default.temporaryDirectory.appendingPathComponent("not-a-repo-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: loose, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: loose) }
        #expect(await ProjectFiles.trackedFiles(in: loose).isEmpty)
    }
}
