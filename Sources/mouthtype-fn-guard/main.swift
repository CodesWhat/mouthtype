import Darwin
import FnRemapKit
import os

// SIGTERM and SIGINT end the process at once, mapping untouched: the app sends SIGTERM after it restored the
// mapping itself. The app ignores both, and an ignored disposition survives exec, so set the default explicitly.
signal(SIGTERM, SIG_DFL)
signal(SIGINT, SIG_DFL)
let log = Logger(subsystem: "com.codeswhat.mouthtype", category: "fnguard")

guard let arguments = FnGuardArguments.parse(CommandLine.arguments) else {
    fputs(FnGuardArguments.usage + "\n", stderr)
    exit(64)
}

switch FnGuard.run(arguments, store: HIDKeyMappingStore()) {
case .removed:
    log.notice("parent \(arguments.parent, privacy: .public) exited, removed the fn remap")
case .alreadyGone:
    log.notice("parent \(arguments.parent, privacy: .public) exited, fn remap already restored")
case let .failed(reason):
    log.error("parent \(arguments.parent, privacy: .public) exited, fn remap not removed: \(reason, privacy: .public)")
    exit(1)
}
