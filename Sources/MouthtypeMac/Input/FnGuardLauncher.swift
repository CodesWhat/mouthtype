import FnRemapKit
import Foundation

/// Starts and stops the helper that clears the Fn remap if the app dies without restoring it.
@MainActor
protocol FnGuarding: AnyObject {
    /// `restoring` is the user's own Fn mapping that the remap displaced, put back if the app dies.
    func start(restoring: FnRemapMapping.Entry?)
    func stop()
}

/// Spawns `mouthtype-fn-guard` from the app bundle in its own session, so the app's process group going away
/// doesn't take it along. At most one lives per app process.
@MainActor
final class FnGuardLauncher: FnGuarding {
    nonisolated static let executableName = "mouthtype-fn-guard"

    private let executable: URL?
    private(set) var pid: pid_t?
    private var warnedMissing = false

    init(executable: URL? = FnGuardLauncher.bundledExecutable()) {
        self.executable = executable
    }

    nonisolated static func bundledExecutable() -> URL? {
        Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(executableName)
    }

    var isRunning: Bool {
        guard let pid else { return false }
        var status: Int32 = 0
        if waitpid(pid, &status, WNOHANG) == 0 { return true }
        self.pid = nil
        return false
    }

    func start(restoring: FnRemapMapping.Entry?) {
        guard !isRunning else { return }
        guard let executable, FileManager.default.isExecutableFile(atPath: executable.path) else {
            if !warnedMissing { Log.hotkey.error("fn guard not found, the remap has no safety net") }
            warnedMissing = true
            return
        }
        pid = Self.spawn(executable, parent: getpid(), displaced: restoring?[FnRemapMapping.dstKey])
        if let pid {
            Log.hotkey.info("fn guard started, pid \(pid, privacy: .public)")
        } else {
            Log.hotkey.error("fn guard did not start, the remap has no safety net")
        }
    }

    /// The remap is already restored when this runs, so the guard is told to go away without touching the mapping.
    func stop() {
        guard let pid else { return }
        self.pid = nil
        kill(pid, SIGTERM)
        // Reaps on a GCD thread: waitpid blocks, and a cooperative-pool thread must never block in a syscall.
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
        Log.hotkey.info("fn guard stopped, pid \(pid, privacy: .public)")
    }

    private nonisolated static func spawn(_ executable: URL, parent: pid_t, displaced: Int64?) -> pid_t? {
        var attributes: posix_spawnattr_t?
        var actions: posix_spawn_file_actions_t?
        guard posix_spawnattr_init(&attributes) == 0 else { return nil }
        defer { posix_spawnattr_destroy(&attributes) }
        guard posix_spawn_file_actions_init(&actions) == 0 else { return nil }
        defer { posix_spawn_file_actions_destroy(&actions) }
        // The app ignores SIGTERM and SIGINT, and ignored signals survive exec: the guard must start with the defaults.
        var defaults = sigset_t()
        sigemptyset(&defaults)
        sigaddset(&defaults, SIGTERM)
        sigaddset(&defaults, SIGINT)
        guard posix_spawnattr_setsigdefault(&attributes, &defaults) == 0 else { return nil }
        let flags = POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT | POSIX_SPAWN_SETSIGDEF
        guard posix_spawnattr_setflags(&attributes, Int16(flags)) == 0 else { return nil }
        for descriptor: Int32 in [0, 1, 2] {
            let mode = descriptor == 0 ? O_RDONLY : O_WRONLY
            guard posix_spawn_file_actions_addopen(&actions, descriptor, "/dev/null", mode, 0) == 0 else { return nil }
        }
        var arguments = [
            executable.path, String(parent),
            String(FnRemapMapping.fnSource), String(FnRemapMapping.fnDestination),
        ]
        if let displaced { arguments.append(String(displaced)) }
        let argv: [UnsafeMutablePointer<CChar>?] = arguments.map { strdup($0) } + [nil]
        defer { argv.forEach { free($0) } }
        var child: pid_t = 0
        guard posix_spawn(&child, executable.path, &actions, &attributes, argv, environ) == 0 else { return nil }
        return child
    }
}
