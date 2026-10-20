import CoreGraphics
import Foundation
import Testing
import MouthtypeCore
@testable import MouthtypeMac

@MainActor
@Suite struct AutomationHotkeySyncTests {
    private let fn = CGEventFlags.maskSecondaryFn.rawValue

    private func events(_ service: HotkeyService, count: Int) async -> [HotkeyEvent] {
        let collector = Task { @MainActor in
            var received: [HotkeyEvent] = []
            for await event in service.events {
                received.append(event)
                if received.count == count { break }
            }
            return received
        }
        let deadline = Task {
            try? await Task.sleep(for: .seconds(1))
            if !Task.isCancelled { collector.cancel() }
        }
        let result = await collector.value
        deadline.cancel()
        return result
    }

    private func service(_ mode: RecordingMode) -> HotkeyService {
        HotkeyService(options: .init(source: .fnFlag, configuration: .init(recordingMode: mode)), otherKeysHeld: { _ in false })
    }

    @Test(.timeLimit(.minutes(1))) func aQuickFnTapStopsAnAdoptedRecordingInsteadOfDiscardingIt() async {
        for mode in [RecordingMode.hold, .toggle] {
            let service = service(mode)
            defer { service.stop() }
            service.adoptLockedRecording()
            let tapWanted = service.shared.recording.load(ordering: .relaxed)
            #expect(tapWanted)
            service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 1_000_000))
            service.process(.init(kind: .flagsChanged, keyCode: 63, flags: 0, timestamp: 20_000_000))
            #expect(await events(service, count: 1) == [.released(at: 1_000_000)])
        }
    }

    @Test(.timeLimit(.minutes(1))) func escapeCancelsAnAdoptedRecording() async {
        let service = service(.hold)
        defer { service.stop() }
        service.adoptLockedRecording()
        service.process(.init(kind: .keyDown, keyCode: 53, flags: 0, timestamp: 5))
        #expect(await events(service, count: 1) == [.cancelled(reason: .escape)])
    }

    @Test func releasingTheLockLetsTheNextPressStartFresh() async {
        let service = service(.hold)
        defer { service.stop() }
        service.adoptLockedRecording()
        service.releaseLock()
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 1_000_000))
        #expect(await events(service, count: 1) == [.pressed(at: 1_000_000)])
    }

    @Test func adoptingMidPressTurnsTheHeldKeyIntoTheLockSoItsReleaseIsSwallowed() async {
        let service = service(.hold)
        defer { service.stop() }
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 1_000_000))
        service.adoptLockedRecording()
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: 0, timestamp: 20_000_000))
        service.process(.init(kind: .flagsChanged, keyCode: 63, flags: fn, timestamp: 900_000_000))
        #expect(await events(service, count: 2) == [.pressed(at: 1_000_000), .released(at: 900_000_000)])
    }
}

/// Runs the real `scripts/mouthtype` with input that must be refused. Valid verbs hand off to `open`, so they stay out.
@Suite struct MouthtypeCLITests {
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("scripts/mouthtype").path

    private func run(_ arguments: [String]) throws -> (status: Int32, out: String, err: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.script] + arguments
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outData, as: UTF8.self), String(decoding: errData, as: UTF8.self))
    }

    @Test(arguments: [
        [], ["bogus"], ["Start"], ["start", "now"], ["stop", "extra"], ["copy-last", "x"],
        ["open", "nowhere"], ["open", "General"], ["open", "settings", "extra"], ["open", "page=general"],
        ["--help", "start"], ["-x"], [""],
    ])
    func refusesBadInputWithUsageOnStderr(arguments: [String]) throws {
        let result = try run(arguments)
        #expect(result.status == 64)
        #expect(result.out.isEmpty)
        #expect(result.err.hasPrefix("usage: mouthtype"))
    }

    @Test(arguments: ["--help", "-h"])
    func helpPrintsUsageToStdoutAndSucceeds(flag: String) throws {
        let result = try run([flag])
        #expect(result.status == 0)
        #expect(result.err.isEmpty)
        #expect(result.out.hasPrefix("usage: mouthtype"))
        for verb in AutomationCommand.verbs { #expect(result.out.contains(verb)) }
    }
}
