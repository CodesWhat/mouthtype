import FnRemapKit
import Foundation

/// `--fn-guard-selftest`: applies the remap, turns it off and on again through the coordinator with the real guard
/// launcher, and logs the guard's pid at each step (category `probe`), pausing between steps so a script can count
/// guard processes. Needs no permissions and no key tap. Leaves the remap off.
@MainActor
enum FnGuardSelfTest {
    static func run(remap: FnRemap) async {
        guard let preferences = UserDefaults(suiteName: "com.codeswhat.mouthtype.guard-selftest") else {
            Log.probe.error("fn-guard-selftest: no scratch defaults")
            return
        }
        preferences.removePersistentDomain(forName: "com.codeswhat.mouthtype.guard-selftest")
        let launcher = FnGuardLauncher()
        let coordinator = FnRemapCoordinator(remap: remap, preferences: preferences, guardian: launcher)
        func step(_ label: String) async {
            let pid = launcher.pid.map(String.init) ?? "none"
            Log.probe.info("fn-guard-selftest: \(label, privacy: .public) guard pid \(pid, privacy: .public), mapping \(remap.currentDescription(), privacy: .public)")
            try? await Task.sleep(for: .seconds(2))
        }
        _ = coordinator.initialSource()
        await step("remap on")
        _ = coordinator.setEnabled(false)
        await step("remap off")
        _ = coordinator.setEnabled(true)
        await step("remap on again")
        _ = coordinator.setEnabled(false)
        await step("remap off, finished")
    }
}
