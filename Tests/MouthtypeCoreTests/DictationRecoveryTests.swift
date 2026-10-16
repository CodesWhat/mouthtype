import Foundation
import Testing
@testable import MouthtypeCore

@Suite struct DictationRecoveryTests {
    @Test func savedRecordingsRemainReachableAfterTheLaunchScanAndFailedAttempts() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let older = try rig.row(.recorded, ago: 3_000, now: now, audioSeconds: 3)
        let newest = try rig.row(.recorded, ago: 600, now: now, audioSeconds: 2)
        let failed = try rig.row(.failed, ago: 4_000, now: now, audioSeconds: 1)
        try rig.row(.cancelled, ago: 20, now: now, audioSeconds: 1)
        try rig.row(.inserted, ago: 10, now: now, audioSeconds: 1)
        try rig.row(.started, ago: -10, now: now, partialSeconds: 1)
        _ = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        let saved = try DictationRecovery.saved(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(saved.map(\.id) == [newest, older, failed])
        try rig.store.finish(newest, status: .cancelled)
        #expect(try DictationRecovery.saved(store: rig.store, archive: rig.archive, now: now, launchedAt: now).map(\.id) == [older, failed])
    }

    @Test(arguments: [DictationStatus.inserted, .cancelled, .tooShort, .empty, .failed])
    func newerEndedActivityKeepsStaleAudioSavedWithoutAnAutomaticOffer(status: DictationStatus) throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let stale = try rig.row(.recorded, ago: 18 * 3600, now: now, audioSeconds: 2)
        let lost = try rig.row(.started, ago: 17 * 3600, now: now)
        let ended = try rig.row(status, ago: 60, now: now)

        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)

        #expect(scan.newest == nil && scan.olderCount == 1 && scan.lostCount == 1)
        #expect(try DictationRecovery.saved(store: rig.store, archive: rig.archive, now: now, launchedAt: now).map(\.id) == [stale])
        for id in [stale, lost] {
            let row = try #require(try rig.store.dictation(id: id))
            #expect(row.status == .failed && row.errorMessage == DictationRecovery.interruptedMessage)
        }
        #expect(try rig.store.dictation(id: ended)?.status == status)
        #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: stale).path))
    }

    @Test(arguments: [18 * 3600.0, 60.0])
    func theLatestCrashIsStillOfferedWhenOnlyOlderAttemptsEnded(ago: TimeInterval) throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.row(.inserted, ago: ago + 60, now: now)
        let crash = try rig.row(.recorded, ago: ago, now: now, audioSeconds: 2)

        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)

        #expect(scan.newest?.id == crash && scan.olderCount == 0 && scan.lostCount == 0)
        #expect(abs((scan.newest?.seconds ?? 0) - 2) < 0.01)
    }

    @Test func activityCompletedAfterLaunchSuppressesTheOldOfferAndLeavesTheLiveTakeUntouched() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let launch = now.addingTimeInterval(-120)
        let stale = try rig.row(.recorded, ago: 300, now: now, audioSeconds: 2)
        try rig.row(.inserted, ago: 60, now: now)
        let live = try rig.row(.started, ago: 30, now: now, partialSeconds: 2)
        let liveAudio = try Data(contentsOf: rig.archive.partialURL(for: live))

        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: launch)

        #expect(scan.newest == nil && scan.olderCount == 1 && scan.lostCount == 0)
        #expect(try rig.store.dictation(id: live)?.status == .started)
        #expect(try rig.store.dictation(id: live)?.errorMessage == nil)
        #expect(try Data(contentsOf: rig.archive.partialURL(for: live)) == liveAudio)
        #expect(try DictationRecovery.saved(store: rig.store, archive: rig.archive, now: now, launchedAt: launch).map(\.id) == [stale])
    }

    private let now = Date(timeIntervalSince1970: 1_791_806_400)

    private struct Rig {
        let dir: URL
        let store: TranscriptStore
        let archive: AudioArchive

        init() throws {
            dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-recovery-\(UUID().uuidString)")
            store = try TranscriptStore(url: dir.appendingPathComponent("mouthtype.sqlite"))
            archive = AudioArchive(supportDirectory: dir)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: dir) }

        /// A row at `status`, `ago` seconds before `now`, with archived audio of `seconds` when asked.
        @discardableResult
        func row(
            _ status: DictationStatus, ago: TimeInterval, now: Date, audioSeconds: Double? = nil, partialSeconds: Double? = nil
        ) throws -> String {
            let id = UUID().uuidString
            try store.begin(DictationStart(id: id, startedAt: now.addingTimeInterval(-ago)))
            if let audioSeconds {
                let entry = try archive.write(samples: [Float](repeating: 0.1, count: Int(audioSeconds * 16_000)), id: id)
                try store.recordCapture(id, CaptureRecord(audioMs: Int(audioSeconds * 1000), audioPath: entry.url.path))
            }
            if let partialSeconds {
                try archive.appendPartial(samples: [Float](repeating: 0.1, count: Int(partialSeconds * 16_000)), id: id)
            }
            switch status {
            case .started, .recorded: break
            case .transcribed:
                try store.recordTranscription(id, TranscriptionRecord(
                    transcription: Transcription(text: "hi", words: [], processingSeconds: 0.1, engineID: "t"), rawText: "hi"
                ))
            case .inserted: try store.recordInsertion(id, InsertionRecord(finalText: "done"))
            case .cancelled, .tooShort, .empty, .failed: try store.finish(id, status: status)
            }
            return id
        }
    }

    @Test func onlyRowsThatNeverEndedAreFound() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let started = try rig.row(.started, ago: 60, now: now, audioSeconds: 2)
        let recorded = try rig.row(.recorded, ago: 120, now: now, audioSeconds: 2)
        let transcribed = try rig.row(.transcribed, ago: 180, now: now, audioSeconds: 2)
        for status in [DictationStatus.inserted, .cancelled, .tooShort, .empty, .failed] {
            try rig.row(status, ago: 30, now: now, audioSeconds: 2)
        }
        let found = try rig.store.unfinished(from: now.addingTimeInterval(-86_400), before: now)
        #expect(found.map(\.id) == [started, recorded, transcribed])
    }

    @Test func theWindowIsTwentyFourHoursAndEndsAtLaunch() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let inside = try rig.row(.recorded, ago: 86_400 - 5, now: now, audioSeconds: 2)
        try rig.row(.recorded, ago: 86_400 + 5, now: now, audioSeconds: 2)
        try rig.row(.recorded, ago: -10, now: now, audioSeconds: 2)   // started after the launch
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(scan.newest?.id == inside && scan.olderCount == 0 && scan.lostCount == 0)
    }

    @Test func theNewestIsOfferedAndEveryRowIsEndedSoNothingIsOfferedTwice() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let old1 = try rig.row(.recorded, ago: 3_000, now: now, audioSeconds: 3)
        let old2 = try rig.row(.transcribed, ago: 2_000, now: now, audioSeconds: 4)
        let newest = try rig.row(.recorded, ago: 600, now: now, audioSeconds: 12)

        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(scan.newest?.id == newest && scan.olderCount == 2)
        #expect(abs((scan.newest?.seconds ?? 0) - 12) < 0.01)
        #expect(scan.newest?.startedAt == now.addingTimeInterval(-600) && scan.newest?.isPartial == false)
        for id in [old1, old2, newest] {
            let row = try #require(try rig.store.dictation(id: id))
            #expect(row.status == .failed && row.errorMessage == "interrupted")
            #expect(FileManager.default.fileExists(atPath: rig.archive.url(for: id).path))
        }

        let next = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(next == RecoveryScan(newest: nil, olderCount: 0, lostCount: 0))
    }

    @Test func rowsWithNoAudioAreFailedAsInterruptedAndNeverOffered() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let nothing = try rig.row(.started, ago: 100, now: now)
        let recordedButGone = try rig.row(.recorded, ago: 200, now: now, audioSeconds: 2)
        try FileManager.default.removeItem(at: rig.archive.url(for: recordedButGone))
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(scan.newest == nil && scan.lostCount == 2)
        for id in [nothing, recordedButGone] {
            let row = try #require(try rig.store.dictation(id: id))
            #expect(row.status == .failed && row.errorMessage == "interrupted")
        }
    }

    @Test func aRecordingThatDiedMidwayIsRecoveredFromItsInProgressCopy() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let id = try rig.row(.started, ago: 90, now: now, partialSeconds: 7)
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        let found = try #require(scan.newest)
        #expect(found.id == id && found.isPartial && found.audioURL == rig.archive.partialURL(for: id))
        #expect(abs(found.seconds - 7) < 0.01)
        #expect(try AudioArchive.read(contentsOf: found.audioURL).count == 7 * 16_000)
    }

    @Test func aHeaderOnlyCopyIsNotAudio() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        try rig.row(.started, ago: 90, now: now, partialSeconds: 0)
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(scan.newest == nil && scan.lostCount == 1)
    }

    @Test func anOlderRowLeavesTheNewerOneOfferedWhenOnlyTheOlderHasAudio() throws {
        let rig = try Rig()
        defer { rig.cleanUp() }
        let older = try rig.row(.recorded, ago: 900, now: now, audioSeconds: 5)
        try rig.row(.started, ago: 30, now: now)
        let scan = try DictationRecovery.scan(store: rig.store, archive: rig.archive, now: now, launchedAt: now)
        #expect(scan.newest?.id == older && scan.olderCount == 0 && scan.lostCount == 1)
    }
}

@Suite struct AudioArchivePartialTests {
    private func archive() -> (AudioArchive, URL) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mouthtype-partial-\(UUID().uuidString)")
        return (AudioArchive(supportDirectory: dir), dir)
    }

    @Test func piecesAppendIntoOneFileThatReadsBackWhole() throws {
        let (archive, dir) = archive()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = (0..<8_000).map { Float($0 % 100) / 200 }
        let second = (0..<4_000).map { -Float($0 % 50) / 100 }
        try archive.appendPartial(samples: first, id: "a")
        try archive.appendPartial(samples: second, id: "a")
        try archive.appendPartial(samples: [], id: "a")
        let read = try AudioArchive.read(contentsOf: archive.partialURL(for: "a"))
        #expect(read.count == 12_000)
        #expect(abs(read[10] - first[10]) < 0.001 && abs(read[8_010] - second[10]) < 0.001)
    }

    @Test func theFinishedWriteReplacesTheInProgressCopy() throws {
        let (archive, dir) = archive()
        defer { try? FileManager.default.removeItem(at: dir) }
        try archive.appendPartial(samples: [0.1, 0.2], id: "a")
        #expect(FileManager.default.fileExists(atPath: archive.partialURL(for: "a").path))
        let entry = try archive.write(samples: [0.1, 0.2, 0.3], id: "a")
        #expect(!FileManager.default.fileExists(atPath: archive.partialURL(for: "a").path))
        #expect(try AudioArchive.read(contentsOf: entry.url).count == 3)
        // The final file is a proper WAV, not the open-ended header.
        #expect(entry.byteSize == 44 + 6)
    }

    @Test func discardingTakesTheCopyAwayAndIsSafeWithoutOne() throws {
        let (archive, dir) = archive()
        defer { try? FileManager.default.removeItem(at: dir) }
        archive.discardPartial(id: "none")
        try archive.appendPartial(samples: [0.1], id: "a")
        archive.discardPartial(id: "a")
        #expect(!FileManager.default.fileExists(atPath: archive.partialURL(for: "a").path))
    }
}
