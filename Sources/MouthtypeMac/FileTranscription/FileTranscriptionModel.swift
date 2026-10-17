import Foundation
import MouthtypeCore
import Observation

@MainActor @Observable
final class FileTranscriptionModel {
    enum State: Equatable { case idle, preparing, transcribing, cancelling, finished, empty, cancelled, failed }
    private(set) var state = State.idle
    private(set) var text = ""
    private(set) var filename = ""
    private(set) var errorMessage: String?
    var isBusy: Bool { state == .preparing || state == .transcribing || state == .cancelling }
    var hasResult: Bool { !text.isEmpty }
    @ObservationIgnored private var source: URL?
    @ObservationIgnored private var job: AudioFileTranscription?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let makeJob: @MainActor () throws -> AudioFileTranscription
    @ObservationIgnored private let canBegin: @MainActor () -> Bool
    @ObservationIgnored private let activityChanged: @MainActor () -> Void
    @ObservationIgnored private let copyText: @MainActor (String) -> Void

    init(makeJob: @escaping @MainActor () throws -> AudioFileTranscription,
         canBegin: @escaping @MainActor () -> Bool = { true },
         activityChanged: @escaping @MainActor () -> Void = {},
         copy: @escaping @MainActor (String) -> Void) {
        self.makeJob = makeJob
        self.canBegin = canBegin
        self.activityChanged = activityChanged
        copyText = copy
    }

    func start(_ source: URL) {
        guard !isBusy else { return }
        guard canBegin() else {
            state = .failed
            errorMessage = "Finish dictation, recovery or updating before transcribing a file."
            return
        }
        do {
            let job = try makeJob()
            self.job = job
            self.source = source
            filename = source.lastPathComponent
            text = ""
            errorMessage = nil
            state = .preparing
            activityChanged()
            task = Task { [weak self] in
                guard let self else { return }
                defer {
                    self.job = nil
                    self.task = nil
                    self.activityChanged()
                }
                do {
                    let result = try await job.run(source) { [weak self] in await self?.decoded() }
                    try Task.checkCancellation()
                    if result.transcription.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.state = .empty
                    } else {
                        self.text = result.transcription.text
                        self.state = .finished
                    }
                } catch is CancellationError {
                    self.state = .cancelled
                } catch {
                    self.state = .failed
                    self.errorMessage = (error as? AudioFileError)?.localizedDescription ?? "Transcription failed. Your original file is unchanged."
                }
            }
        } catch {
            state = .failed
            errorMessage = (error as? AudioFileError)?.localizedDescription ?? "The speech model is not ready. Try again when it has loaded."
        }
    }

    private func decoded() {
        if state == .preparing { state = .transcribing }
    }

    func cancel() {
        guard isBusy else { return }
        state = .cancelling
        task?.cancel()
    }

    func copy() {
        guard !isBusy, hasResult else { return }
        copyText(text)
    }

    func save(to destination: URL) throws {
        guard !isBusy else { throw AudioFileError.busy }
        guard hasResult else { throw AudioFileError.empty }
        guard let source, destination.standardizedFileURL.resolvingSymlinksInPath() != source.standardizedFileURL.resolvingSymlinksInPath() else {
            throw AudioFileError.cannotReplaceSource
        }
        try Data(text.utf8).write(to: destination, options: .atomic)
    }
}
