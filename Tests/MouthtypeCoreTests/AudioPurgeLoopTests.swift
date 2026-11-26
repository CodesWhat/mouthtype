import Foundation
import Testing

@testable import MouthtypeCore

private actor Recorder {
    var sleeps: [Duration] = []
    var purges = 0
    var idleChecks = 0
    func sleep(_ d: Duration) { sleeps.append(d) }
    func purged() { purges += 1 }
    func checkIdle(_ script: [Bool]) -> Bool {
        defer { idleChecks += 1 }
        return script[min(idleChecks, script.count - 1)]
    }
}

@Suite struct AudioPurgeLoopTests {
    @Test func busyTickRetriesSoonAndThenPurgesOnTheFullInterval() async {
        let rec = Recorder()
        let task = Task {
            await AudioPurgeLoop.run(
                interval: .seconds(100), busyRetry: .seconds(5),
                sleep: { await rec.sleep($0) },
                shouldStop: { await rec.purges >= 2 },
                isIdle: { await rec.checkIdle([false, true, true]) },
                purge: { await rec.purged() })
        }
        await task.value
        #expect(await rec.sleeps == [.seconds(100), .seconds(5), .seconds(100)])
        #expect(await rec.purges == 2)
    }

    @Test func stopsWithoutPurgingWhenTerminating() async {
        let rec = Recorder()
        await AudioPurgeLoop.run(
            interval: .seconds(1), busyRetry: .seconds(1),
            sleep: { await rec.sleep($0) },
            shouldStop: { true }, isIdle: { true }, purge: { await rec.purged() })
        #expect(await rec.purges == 0)
    }

    @Test func cancellationEndsTheLoop() async {
        let rec = Recorder()
        let task = Task {
            await AudioPurgeLoop.run(
                sleep: { _ in
                    await rec.sleep(.zero)
                    try? await Task.sleep(for: .seconds(60))
                },
                shouldStop: { false }, isIdle: { true }, purge: { await rec.purged() })
        }
        while await rec.sleeps.isEmpty { await Task.yield() }
        task.cancel()
        await task.value
        #expect(await rec.purges == 0)
    }
}
