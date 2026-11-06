import AppKit
import Foundation
import Testing
@testable import MouthtypeMac

@MainActor @Suite(.timeLimit(.minutes(1))) struct AppInstanceLeaseTests {
    private func directory() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-instance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func onlyOneOwnerCanHoldTheSameSupportDirectory() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("support/instance.lock")
        var first = try AppInstanceLease.acquire(at: url)
        try #require(first != nil)
        try withExtendedLifetime(first) { () throws -> Void in
            #expect(try AppInstanceLease.acquire(at: url) == nil)
        }
        first = nil
        let second = try #require(try AppInstanceLease.acquire(at: url))
        withExtendedLifetime(second) {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func staleFileContentsDoNotBlockANewOwner() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let stale = Data("old process identifier".utf8)
        try stale.write(to: url)
        let owner = try #require(try AppInstanceLease.acquire(at: url))
        try withExtendedLifetime(owner) { () throws -> Void in
            #expect(try Data(contentsOf: url) == stale)
            #expect(try AppInstanceLease.acquire(at: url) == nil)
        }
    }

    @Test func filesystemErrorsAreReportedInsteadOfTreatedAsAnotherOwner() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        #expect(throws: (any Error).self) {
            try AppInstanceLease.acquire(at: file.appendingPathComponent("instance.lock"))
        }
    }

    @Test func launchWorkRunsAfterOwnershipAndTheDelegateKeepsIt() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let delegate = AppDelegate()
        var launches = 0
        var heldDuringLaunch = false
        let started = try delegate.beginOwnedLaunch(at: url) {
            launches += 1
            heldDuringLaunch = (try? AppInstanceLease.acquire(at: url)) == nil
        }
        #expect(started && launches == 1 && heldDuringLaunch)
        try withExtendedLifetime(delegate) { () throws -> Void in
            #expect(try AppInstanceLease.acquire(at: url) == nil)
        }
    }

    @Test func anotherOwnerPreventsSharedLaunchWork() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let owner = try #require(try AppInstanceLease.acquire(at: url))
        defer { withExtendedLifetime(owner) {} }
        let delegate = AppDelegate()
        var launched = false
        let started = try delegate.beginOwnedLaunch(at: url) { launched = true }
        #expect(!started && !launched)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func aRunningOlderInstancePreventsCreatingTheLockOrRunningLaunchWork() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let delegate = AppDelegate()
        var launched = false
        let started = try delegate.beginOwnedLaunch(at: url, anotherInstanceIsRunning: true) { launched = true }
        #expect(!started && !launched && !FileManager.default.fileExists(atPath: url.path))
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    @Test func ownershipFailureDoesNotRunSharedLaunchWork() throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let delegate = AppDelegate()
        var launched = false
        #expect(throws: (any Error).self) {
            try delegate.beginOwnedLaunch(at: file.appendingPathComponent("instance.lock")) { launched = true }
        }
        #expect(!launched)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateNow)
    }

    private func processProbe(at url: URL) async throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "-I", "-S", "-c",
            """
            import fcntl, os, signal, sys
            signal.alarm(5)
            descriptor = os.open(sys.argv[1], os.O_RDWR | os.O_CREAT, 0o600)
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                sys.exit(73)
            os._exit(0)
            """,
            url.path,
        ]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        _ = try await runProcess(process)
        return process.terminationStatus
    }

    @Test func aSeparateProcessCannotTakeALiveOwnersLock() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let owner = try #require(try AppInstanceLease.acquire(at: url))
        defer { withExtendedLifetime(owner) {} }
        let status = try await processProbe(at: url)
        #expect(status == 73)
    }

    @Test func anAbruptProcessExitReleasesOwnershipWithoutDeletingTheFile() async throws {
        let dir = try directory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("instance.lock")
        let status = try await processProbe(at: url)
        #expect(status == 0 && FileManager.default.fileExists(atPath: url.path))
        let owner = try #require(try AppInstanceLease.acquire(at: url))
        defer { withExtendedLifetime(owner) {} }
        let blocked = try await processProbe(at: url)
        #expect(blocked == 73)
    }
}
