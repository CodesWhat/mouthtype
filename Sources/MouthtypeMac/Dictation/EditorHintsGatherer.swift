import AppKit
import Darwin
import Foundation
import MouthtypeCore

/// "Code names from your editor". Off unless the user turns it on.
enum EditorHintsSetting {
    static let key = "useEditorCodeNames"

    static func isEnabled(_ defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: key)
    }

    static func set(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: key)
    }
}

/// The apps editor hints run in. Anything else gathers nothing.
enum EditorHintsSurface: Equatable, Sendable {
    case vscode(supportFolder: String)
    case xcode
    case terminal

    static func of(bundleID: String?) -> EditorHintsSurface? {
        switch bundleID {
        case "com.microsoft.VSCode": .vscode(supportFolder: "Code")
        case "com.microsoft.VSCodeInsiders": .vscode(supportFolder: "Code - Insiders")
        case "com.todesktop.230313mzl4w4u92": .vscode(supportFolder: "Cursor")
        case "com.apple.dt.Xcode": .xcode
        case let id? where PasteSettings.supportsChunking(id): .terminal
        default: nil
        }
    }

    /// Only a source editor's text area is read for cursor text. Search fields, secure fields and anything with a
    /// subrole are not. (The integrated terminal in VS Code and Cursor is told apart by its label, in
    /// `EditorAccessibility`.)
    static func isSourceEditor(role: String?, subrole: String?) -> Bool {
        role == "AXTextArea" && (subrole ?? "").isEmpty
    }

    var titleStyle: EditorHints.TitleStyle? {
        switch self {
        case .vscode: .vscode
        case .xcode: .xcode
        case .terminal: nil
        }
    }
}

/// Starts the per-dictation gather. Everything is read in memory for that one dictation, nothing is stored or logged,
/// and the work runs under `EditorHints.defaultDeadline`.
@MainActor
enum EditorHintsGatherer {
    /// What the focused app can give, injected so tests need no Accessibility. The readers block, so they run off the
    /// main thread, and each takes the instant it must finish by.
    struct Readers: Sendable {
        var cursorContext: @Sendable (_ focus: FocusSnapshot, _ deadline: ContinuousClock.Instant) -> InsertionContext?
        var documentURL: @Sendable (_ focus: FocusSnapshot, _ deadline: ContinuousClock.Instant) -> URL?
        var workingDirectory: @Sendable (_ terminalPID: pid_t, _ windowTitle: String?) -> URL?
        var workspaceFolder: @Sendable (_ supportFolder: String, _ projectName: String) -> URL?

        static let system = Readers(
            cursorContext: { EditorAccessibility.cursorContext(focus: $0, deadline: $1) },
            documentURL: { EditorAccessibility.documentURL(focus: $0, deadline: $1) },
            workingDirectory: { TerminalWorkingDirectory.current(terminalPID: $0, windowTitle: $1) },
            workspaceFolder: { WorkspaceFolder.resolve(supportFolder: $0, projectName: $1) }
        )
    }

    /// Nil, with no reader called, unless the switch and the saved-word boost are both on, the app is on the list and
    /// the field isn't secure. Nothing is read here: the focus taken at dictation start is handed to the detached
    /// gather, which does every Accessibility read inside its deadline.
    static func start(
        enabled: Bool, boostEnabled: Bool, focus: FocusSnapshot, readers: Readers,
        deadline: Duration = EditorHints.defaultDeadline
    ) -> Task<[VocabularyBias.Term], Never>? {
        guard enabled, boostEnabled, !focus.isSecure, let surface = EditorHintsSurface.of(bundleID: focus.bundleID) else { return nil }

        let limit = ContinuousClock.now + deadline
        // Terminals report their whole screen as the field's text, so only a source editor gives a cursor window.
        var readCursor: (@Sendable (ContinuousClock.Instant) -> InsertionContext?)?
        if surface != .terminal, EditorHintsSurface.isSourceEditor(role: focus.role, subrole: focus.subrole) {
            let read = readers.cursorContext
            readCursor = { @Sendable until in read(focus, until) }
        }
        let title = focus.windowTitle
        let pid = focus.pid
        let parsed = surface.titleStyle.map { EditorHints.parseTitle(title ?? "", style: $0) }

        let workingDirectory = readers.workingDirectory
        let workspaceFolder = readers.workspaceFolder
        let documentURL = readers.documentURL
        let files: @Sendable () async -> [String] = {
            var root: URL?
            switch surface {
            case .terminal:
                if let pid { root = workingDirectory(pid, title).flatMap(ProjectFiles.repositoryRoot(containing:)) }
            case .xcode:
                let document = await EditorHints.runBlocking(until: limit) { documentURL(focus, limit) }
                root = document.flatMap { ProjectFiles.repositoryRoot(containing: $0.deletingLastPathComponent()) }
            case .vscode(let supportFolder):
                if let project = parsed?.project {
                    root = workspaceFolder(supportFolder, project).flatMap(ProjectFiles.repositoryRoot(containing:))
                }
            }
            guard let root else { return [] }
            return [root.lastPathComponent] + (await ProjectFiles.trackedFiles(in: root))
        }
        let input = EditorHints.Input(
            windowTitle: title, titleStyle: surface.titleStyle, readCursor: readCursor, files: files
        )
        return Task.detached { await EditorHints.gather(input, deadline: deadline) }
    }
}

/// The working directory of the terminal's foreground shell, from the process tree. Needs no permission for the
/// user's own processes. A terminal whose shells aren't its children (iTerm2 uses a separate server) gives nil.
enum TerminalWorkingDirectory {
    struct Entry: Equatable {
        var pid: pid_t
        var parent: pid_t
        var isForeground: Bool
        var hasTTY: Bool
        var started: UInt64
        var directory: String?
    }

    static func current(terminalPID: pid_t, windowTitle: String?) -> URL? {
        let shells = descendants(of: terminalPID, in: allProcesses()).filter { $0.isForeground && $0.hasTTY }.map { entry in
            var entry = entry
            entry.directory = directory(of: entry.pid)
            return entry
        }
        return choose(from: shells, windowTitle: windowTitle)
    }

    /// Foreground processes on a terminal, by directory. One directory wins outright. With several tabs, the one whose
    /// folder name is in the window title, else the most recently started.
    static func choose(from processes: [Entry], windowTitle: String?) -> URL? {
        let candidates = processes.filter { $0.isForeground && $0.hasTTY }
            .compactMap { process -> (path: String, started: UInt64)? in
                guard let directory = process.directory, directory != "/" else { return nil }
                return (directory, process.started)
            }
        guard !candidates.isEmpty else { return nil }
        let directories = Set(candidates.map(\.path))
        if directories.count == 1, let only = directories.first { return URL(fileURLWithPath: only) }
        if let title = windowTitle?.lowercased() {
            let named = candidates.filter { title.contains(URL(fileURLWithPath: $0.path).lastPathComponent.lowercased()) }
            if Set(named.map(\.path)).count == 1, let match = named.first { return URL(fileURLWithPath: match.path) }
        }
        return candidates.max { $0.started < $1.started }.map { URL(fileURLWithPath: $0.path) }
    }

    static func descendants(of root: pid_t, in processes: [Entry]) -> [Entry] {
        let children = Dictionary(grouping: processes, by: \.parent)
        var found: [Entry] = []
        var queue = children[root] ?? []
        while !queue.isEmpty, found.count < 500 {
            let next = queue.removeFirst()
            found.append(next)
            queue += children[next.pid] ?? []
        }
        return found
    }

    private static func allProcesses() -> [Entry] {
        let capacity = proc_listallpids(nil, 0)
        guard capacity > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(capacity) + 32)
        let count = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { $0 > 0 ? read($0) : nil }
    }

    private static func read(_ pid: pid_t) -> Entry? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return Entry(
            pid: pid, parent: pid_t(info.pbi_ppid), isForeground: info.pbi_pgid == info.e_tpgid,
            hasTTY: info.e_tdev != 0 && info.e_tdev != UInt32.max, started: info.pbi_start_tvsec,
            directory: nil
        )
    }

    static func directory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafeBytes(of: &info.pvi_cdir.vip_path) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return bytes.isEmpty ? nil : String(decoding: bytes, as: UTF8.self)
        }
    }
}

/// VS Code and Cursor keep a small `workspace.json` per opened folder. A project name from the window title maps to a
/// folder only when exactly one existing folder has that name, so a guess never picks the wrong project.
enum WorkspaceFolder {
    static func resolve(supportFolder: String, projectName: String, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let storage = home.appendingPathComponent("Library/Application Support/\(supportFolder)/User/workspaceStorage")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: storage.path) else { return nil }
        var matches = Set<String>()
        for entry in entries.prefix(500) {
            let file = storage.appendingPathComponent(entry).appendingPathComponent("workspace.json")
            guard let data = try? Data(contentsOf: file), data.count < 4_096,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let folder = json["folder"] as? String, folder.hasPrefix("file://"),
                  let url = URL(string: folder), url.lastPathComponent == projectName,
                  FileManager.default.fileExists(atPath: url.path) else { continue }
            matches.insert(url.path)
        }
        return matches.count == 1 ? matches.first.map { URL(fileURLWithPath: $0) } : nil
    }
}
