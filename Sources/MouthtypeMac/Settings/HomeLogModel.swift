import AppKit
import MouthtypeCore
import Observation

/// One row of the Home log. `text` is nil for a take that never produced a transcript but still has audio on disk.
struct HomeTake: Identifiable, Equatable {
    var id: String
    var startedAt: Date
    var text: String?
    var appName: String?
    var recoverable: RecoverableDictation?
}

/// The data behind the Home page: recent dictations from the transcript store, newest first, plus the saved audio
/// each one can be recovered from. Secure-field takes never show, matching the Recent Dictations menu.
@MainActor @Observable final class HomeLogModel {
    static let limit = 50

    var store: TranscriptStore?
    var saved: @MainActor () async throws -> [RecoverableDictation]
    var canRecover: @MainActor () -> Bool
    var recoverTake: @MainActor (RecoverableDictation) -> Void
    private let copyText: @MainActor (String) -> Void
    private(set) var takes: [HomeTake] = []
    private(set) var error: String?
    private(set) var lastCopiedID: String?

    init(store: TranscriptStore? = nil,
         saved: @escaping @MainActor () async throws -> [RecoverableDictation] = { [] },
         canRecover: @escaping @MainActor () -> Bool = { true },
         recover: @escaping @MainActor (RecoverableDictation) -> Void = { _ in },
         copy: @escaping @MainActor (String) -> Void = { text in
             NSPasteboard.general.clearContents()
             NSPasteboard.general.setString(text, forType: .string)
         }) {
        self.store = store
        self.saved = saved
        self.canRecover = canRecover
        self.recoverTake = recover
        self.copyText = copy
    }

    /// Loads the log, then attaches saved audio. The text shows first so a slow audio scan never blanks the page.
    func reload() async {
        loadText()
        do {
            attach(try await saved())
        } catch {
            Log.app.error("home saved recordings unavailable: \(error.localizedDescription, privacy: .public)")
        }
    }

    func loadText() {
        guard let store else { takes = []; error = "Recent dictations are unavailable."; return }
        do {
            takes = Array(Self.takes(from: try store.recent(limit: Self.limit * 4)).prefix(Self.limit))
            error = nil
        } catch {
            takes = []
            self.error = error.localizedDescription
        }
    }

    /// Newest first. Secure rows and blank transcripts are dropped.
    static func takes(from records: [DictationRecord]) -> [HomeTake] {
        records
            .filter { $0.isSecure != true && !($0.finalText ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.startedAt > $1.startedAt }
            .map { HomeTake(id: $0.id, startedAt: Date(timeIntervalSince1970: $0.startedAt), text: $0.finalText, appName: $0.appName) }
    }

    /// Saved audio joins its take by id. A saved recording with no transcript becomes its own take, in date order.
    func attach(_ recordings: [RecoverableDictation]) {
        var byID = Dictionary(recordings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var merged = takes.map { take -> HomeTake in
            var take = take
            take.recoverable = byID.removeValue(forKey: take.id)
            return take
        }
        for recording in byID.values {
            merged.append(HomeTake(id: recording.id, startedAt: recording.startedAt, text: nil, appName: nil, recoverable: recording))
        }
        takes = Array(merged.sorted { $0.startedAt > $1.startedAt }.prefix(Self.limit))
    }

    func copy(_ take: HomeTake) {
        guard let text = take.text else { return }
        copyText(text)
        lastCopiedID = take.id
    }

    func recover(_ take: HomeTake) {
        guard let recording = take.recoverable, canRecover() else { return }
        recoverTake(recording)
    }
}
