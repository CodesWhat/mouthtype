import AppKit
import Foundation
import MouthtypeCore
import Testing
import os
@testable import MouthtypeMac

@MainActor @Suite(.timeLimit(.minutes(1))) struct LaunchPathTests {
    private func defaults() -> (UserDefaults, () -> Void) {
        let name = "LaunchPathTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (defaults, { defaults.removePersistentDomain(forName: name) })
    }

    @Test func backgroundRegistrationFinishesBeforeADrawPathReturns() async {
        FontRegistry.registerInBackground()
        // Draw paths gate on ensureRegistered, which waits for the background pass instead of reading a half-registered set.
        FontRegistry.ensureRegistered()
        #expect(FontRegistry.registered == FontRegistry.families)
        #expect(Typography.systemaAvailable)
        #expect(NSFont(name: FontRegistry.monoName, size: 9) != nil)
    }

    @Test func theStatusItemStepNeverRegistersFontsOnTheMainThread() async {
        FontRegistry.resetForTesting()
        let delegate = AppDelegate()
        var finished = false
        delegate.beginLaunch(finish: { _ in finished = true })
        // Straight after the status item: nothing has registered on main, and the rest of launch hasn't started.
        #expect(!FontRegistry.registeredOnMain)
        #expect(!finished)
        for _ in 0..<1000 where !finished { try? await Task.sleep(for: .milliseconds(10)) }
        #expect(finished)
        #expect(FontRegistry.registered == FontRegistry.families)
    }

    @Test func registrationIsSafeFromOtherThreads() async {
        let results = await withTaskGroup(of: [String].self) { group in
            for _ in 0..<4 { group.addTask { FontRegistry.registerBundledFonts() } }
            var all: [[String]] = []
            for await result in group { all.append(result) }
            return all
        }
        #expect(results.allSatisfy { $0 == FontRegistry.families })
    }

    @Test func settingsModelsStayUnbuiltUntilFirstPresentAndThenGetTheStore() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let delegate = AppDelegate()
        delegate.settingsStore = store
        #expect(!delegate.settingsWindowBuilt)
        let window = delegate.settingsWindow
        #expect(delegate.settingsWindowBuilt)
        #expect(window.model.home.store === store)
        #expect(window.model.stats.store === store)
        #expect(window.model.spellingSuggestions?.store === store)
    }

    @Test func aURLDuringLaunchIsQueuedThenReplayedAndALateWindowIsRewired() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let delegate = AppDelegate()
        // Something builds the window before launch has a store.
        let window = delegate.settingsWindow
        #expect(window.model.home.store == nil)
        delegate.application(NSApp, open: [URL(string: "mouthtype://record/start")!])
        delegate.application(NSApp, open: [URL(string: "mouthtype://record/stop")!])
        #expect(delegate.pendingOpenCount == 2)
        delegate.settingsStore = store
        delegate.finishLaunch()
        #expect(delegate.launchComplete)
        #expect(delegate.pendingOpenCount == 0)
        #expect(window.model.home.store === store)
        #expect(window.model.stats.store === store)
    }

    private func url() -> [URL] { [URL(string: "mouthtype://record/start")!] }

    @Test func aQuitAfterAQueuedURLWaitsForTheReplayThenRepliesTrueOnce() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.application(NSApplication.shared, open: url())
        #expect(delegate.deferQuitForQueuedURLs(sender: NSApplication.shared))
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _, ready in
                replies.append(ready); done.resume()
            }
            #expect(replies.isEmpty)
            delegate.finishLaunch()
        }
        await Task.yield()
        #expect(delegate.pendingOpenCount == 0)
        #expect(replies == [true])
    }

    @Test func aQuitWithAnEmptyQueueIsImmediate() {
        let delegate = AppDelegate()
        #expect(!delegate.deferQuitForQueuedURLs(sender: NSApplication.shared))
    }

    @Test func aQuitThatOutlastsTheDeadlineDropsTheQueueAndRepliesOnce() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.quitDeadline = .zero
        delegate.application(NSApplication.shared, open: url())
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _, ready in
                replies.append(ready); done.resume()
            }
            #expect(delegate.deferQuitForQueuedURLs(sender: NSApplication.shared))
        }
        await Task.yield()
        #expect(delegate.pendingOpenCount == 0)
        #expect(replies == [true])
        // A late finishLaunch has nothing held and doesn't reply again.
        delegate.finishLaunch()
        await Task.yield()
        #expect(replies == [true])
    }

    @Test func anAbandonedLaunchDropsTheQueueAndReleasesTheQuit() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.application(NSApplication.shared, open: url())
        #expect(delegate.deferQuitForQueuedURLs(sender: NSApplication.shared))
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _, ready in
                replies.append(ready); done.resume()
            }
            delegate.abandonLaunch(reason: "test")
        }
        #expect(delegate.pendingOpenCount == 0)
        #expect(replies == [true])
    }

    @Test func theStoreOpensOffTheMainActorAndLaunchContinuesOnceWithIt() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("launch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = try TranscriptStore(url: dir.appendingPathComponent("history.sqlite"))
        let held = HeldStoreOpen(outcome: StoreOpenOutcome(store: store))
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        var outcomes: [StoreOpenOutcome] = []
        delegate.openStoreOffMain { outcomes.append($0) }
        // Back on the main actor with the open still held shut.
        #expect(outcomes.isEmpty)
        #expect(delegate.storeOpenInFlight)
        for _ in 0..<1000 where !held.started { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(held.started)
        #expect(!held.ranOnMainThread)
        // Main-actor work goes on meanwhile: a URL queues and a window built early has no store yet.
        delegate.application(NSApp, open: url())
        #expect(delegate.pendingOpenCount == 1)
        #expect(delegate.settingsWindow.model.home.store == nil)
        #expect(!delegate.launchComplete)
        #expect(outcomes.isEmpty)
        held.release()
        for _ in 0..<1000 where outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        // Give a second delivery the same chance to land.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.store === store)
        #expect(outcomes.first?.failure == nil)
        #expect(!held.timedOut)
        #expect(held.calls == 1)
        #expect(!delegate.storeOpenInFlight)
    }

    @Test func aFailedOpenStillContinuesLaunchOnceWithNoStore() async {
        let held = HeldStoreOpen(outcome: StoreOpenOutcome(failure: "disk I/O error"))
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        var outcomes: [StoreOpenOutcome] = []
        delegate.openStoreOffMain { outcomes.append($0) }
        #expect(outcomes.isEmpty)
        held.release()
        for _ in 0..<1000 where outcomes.isEmpty { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(outcomes.count == 1)
        #expect(outcomes.first?.store == nil)
        #expect(outcomes.first?.failure == "disk I/O error")
        #expect(!held.timedOut)
        #expect(!held.ranOnMainThread)
    }

    @Test func aQuitDuringTheOpenWaitsForItThenRepliesOnceAfterLaunchContinues() async {
        let held = HeldStoreOpen(outcome: StoreOpenOutcome())
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        var events: [String] = []
        delegate.openStoreOffMain { _ in events.append("launch") }
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _, ready in
                events.append("reply \(ready)"); done.resume()
            }
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            // Asked again while it waits: still one reply.
            #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
            #expect(events.isEmpty)
            held.release()
        }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(events == ["launch", "reply true"])
        #expect(!held.timedOut)
    }

    /// Waits for `count` replies with its own bound, so a quit that is never answered fails the test instead of hanging it.
    private func replies(_ count: Int, in box: ReplyBox, within limit: Duration = .seconds(2)) async {
        let end = ContinuousClock.now + limit
        while box.replies.count < count, ContinuousClock.now < end { try? await Task.sleep(for: .milliseconds(5)) }
    }

    @Test func aQuitOutwaitsAStuckOpenOnlyUntilTheDeadlineAndALateOpenChangesNothing() async {
        // Held far past this test's own bound: only the deadline can answer the quit.
        let held = HeldStoreOpen(outcome: StoreOpenOutcome(), patience: .seconds(20))
        defer { held.release() }
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        delegate.storeQuitDeadline = .milliseconds(50)
        let box = ReplyBox()
        var launches = 0
        delegate.replyToTermination = { _, ready in box.replies.append(ready) }
        delegate.openStoreOffMain { _ in launches += 1 }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        #expect(box.replies.isEmpty)
        await replies(1, in: box)
        #expect(box.replies == [true])
        #expect(delegate.storeOpenInFlight)
        #expect(launches == 0)
        // The open comes back after the quit was answered: no second reply and no launch on the way out.
        held.release()
        for _ in 0..<400 where delegate.storeOpenInFlight { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(!delegate.storeOpenInFlight)
        #expect(box.replies == [true])
        #expect(launches == 0)
        #expect(!held.timedOut)
    }

    @Test func theQueuedURLDeadlineDuringAStuckOpenStillEndsInOneReply() async {
        let held = HeldStoreOpen(outcome: StoreOpenOutcome(), patience: .seconds(20))
        defer { held.release() }
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        delegate.quitDeadline = .milliseconds(20)
        delegate.storeQuitDeadline = .milliseconds(50)
        let box = ReplyBox()
        delegate.replyToTermination = { _, ready in box.replies.append(ready) }
        delegate.openStoreOffMain { _ in }
        delegate.application(NSApplication.shared, open: url())
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        await replies(1, in: box)
        #expect(box.replies == [true])
        #expect(delegate.pendingOpenCount == 0)
        #expect(delegate.storeOpenInFlight)
        held.release()
        for _ in 0..<400 where delegate.storeOpenInFlight { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(box.replies == [true])
    }

    @Test func aDeadlineDuringAQuarantineWaitsForItToFinishThenRepliesOnce() async {
        let held = HeldStoreOpen(outcome: StoreOpenOutcome(), patience: .seconds(20), quarantines: true)
        defer { held.releaseQuarantine(); held.release() }
        let delegate = AppDelegate()
        delegate.openStore = { held.open($0) }
        delegate.storeQuitDeadline = .milliseconds(30)
        let box = ReplyBox()
        delegate.replyToTermination = { _, ready in box.replies.append(ready) }
        delegate.openStoreOffMain { _ in }
        for _ in 0..<400 where !held.started { try? await Task.sleep(for: .milliseconds(5)) }
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        // Well past the deadline, with the files still moving: no reply yet.
        try? await Task.sleep(for: .milliseconds(300))
        #expect(box.replies.isEmpty)
        held.releaseQuarantine()
        await replies(1, in: box)
        #expect(box.replies == [true])
        #expect(delegate.storeOpenInFlight)
        held.release()
        for _ in 0..<400 where delegate.storeOpenInFlight { try? await Task.sleep(for: .milliseconds(5)) }
        try? await Task.sleep(for: .milliseconds(50))
        #expect(box.replies == [true])
    @Test func aQuitCancelledDuringAnUpdateInstallUnblocksNewWork() {
        let delegate = AppDelegate()
        var activity = UpdateActivity.recovering
        delegate.appUpdater = AppUpdater(driver: nil, activity: { activity })
        delegate.appUpdater.updateWillRelaunch()
        #expect(delegate.appUpdater.blocksNewWork && !delegate.appUpdater.allowsTermination)
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!delegate.appUpdater.blocksNewWork && delegate.appUpdater.installDeferred)
        activity = .idle
        #expect(delegate.appUpdater.allowsTermination)
    }

    @Test func aRetriedInstallCannotQuitThroughBusyWork() {
        let delegate = AppDelegate()
        var activity = UpdateActivity.idle
        delegate.appUpdater = AppUpdater(driver: nil, activity: { activity })
        delegate.appUpdater.updateWillRelaunch()
        delegate.appUpdater.installWasDeferred()
        activity = .fileTranscription
        delegate.appUpdater.installWillProceed()
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateCancel)
        #expect(!delegate.appUpdater.blocksNewWork && delegate.appUpdater.installDeferred)
    }

    @Test func aHeldQuitCancelledDuringAnUpdateInstallUnblocksNewWork() async {
        let delegate = AppDelegate()
        var replies: [Bool] = []
        delegate.appUpdater = AppUpdater(driver: nil, activity: { .recovering })
        delegate.application(NSApplication.shared, open: url())
        #expect(delegate.applicationShouldTerminate(NSApplication.shared) == .terminateLater)
        delegate.appUpdater.updateWillRelaunch()
        await withCheckedContinuation { done in
            delegate.replyToTermination = { _, ready in
                replies.append(ready); done.resume()
            }
            delegate.abandonLaunch(reason: "test")
        }
        #expect(replies == [false])
        #expect(!delegate.appUpdater.blocksNewWork && delegate.appUpdater.installDeferred)
    }

    @Test func burstsOfRefreshRequestsRunOnce() async {
        let (defaults, cleanup) = defaults()
        defer { cleanup() }
        let model = SettingsModel(defaults: defaults)
        let before = model.refreshCount
        for _ in 0..<20 { model.scheduleRefresh() }
        #expect(model.refreshCount == before)
        for _ in 0..<1000 where model.refreshCount == before { try? await Task.sleep(for: .milliseconds(10)) }
        // The burst is one refresh: give any extra one the same chance to land.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshCount == before + 1)
    }

    @Test func anImmediateRefreshCoversAPendingRequest() async {
        let (defaults, cleanup) = defaults()
        defer { cleanup() }
        let model = SettingsModel(defaults: defaults)
        let before = model.refreshCount
        model.scheduleRefresh()
        model.refresh()
        try? await Task.sleep(for: .milliseconds(50))
        #expect(model.refreshCount == before + 1)
    }

    @Test func fontFamiliesAreListedOnceUntilTheFontSetChanges() {
        FontFamilyCache.invalidate()
        let start = FontFamilyCache.loads
        let first = FontFamilyCache.families()
        #expect(FontFamilyCache.families() == first)
        #expect(FontFamilyCache.loads == start + 1)
        NotificationCenter.default.post(name: Notification.Name("NSFontSetChangedNotification"), object: nil)
        _ = FontFamilyCache.families()
        #expect(FontFamilyCache.loads == start + 2)
    }
}

/// A store open the test holds shut. It gives up after `patience`, so a launch that runs it on the main thread fails
/// its expectations instead of hanging the suite.
private final class HeldStoreOpen: Sendable {
    private struct State {
        var calls = 0
        var ranOnMainThread = false
        var timedOut = false
    }

    private let gate = DispatchSemaphore(value: 0)
    private let quarantineGate = DispatchSemaphore(value: 0)
    private let state = OSAllocatedUnfairLock(initialState: State())
    private let outcome: StoreOpenOutcome
    private let patience: DispatchTimeInterval
    private let quarantines: Bool

    /// With `quarantines`, the open first sits inside the quarantine step until `releaseQuarantine()`.
    init(outcome: StoreOpenOutcome, patience: DispatchTimeInterval = .seconds(2), quarantines: Bool = false) {
        self.outcome = outcome
        self.patience = patience
        self.quarantines = quarantines
    }

    var started: Bool { state.withLock { $0.calls > 0 } }
    var calls: Int { state.withLock { $0.calls } }
    var ranOnMainThread: Bool { state.withLock { $0.ranOnMainThread } }
    var timedOut: Bool { state.withLock { $0.timedOut } }

    func open(_ activity: StoreOpenActivity) -> StoreOpenOutcome {
        let onMain = Thread.isMainThread
        let quarantining = quarantines && activity.beginQuarantine()
        state.withLock {
            $0.calls += 1
            $0.ranOnMainThread = onMain
        }
        if quarantining {
            if quarantineGate.wait(timeout: .now() + patience) == .timedOut { state.withLock { $0.timedOut = true } }
            activity.endQuarantine()
        }
        if gate.wait(timeout: .now() + patience) == .timedOut { state.withLock { $0.timedOut = true } }
        return outcome
    }

    func release() { gate.signal() }
    func releaseQuarantine() { quarantineGate.signal() }
}

@MainActor private final class ReplyBox {
    var replies: [Bool] = []
}

@Suite struct PhrasesHealthTests {
    @Test func theFileIsReadAgainOnlyWhenItChanges() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("phrases-health-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("phrases.json")
        let phrases = FilePhrases(url: url)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthReads.withLock { $0 } == 1)
        try Data("not json".utf8).write(to: url)
        #expect(phrases.healthError() != nil)
        #expect(phrases.healthError() != nil)
        #expect(phrases.healthReads.withLock { $0 } == 2)
        try Data("[]\n".utf8).write(to: url)
        #expect(phrases.healthError() == nil)
        #expect(phrases.healthReads.withLock { $0 } == 3)
    }
}
