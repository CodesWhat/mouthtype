import Foundation

enum Machine {
    static func collect() -> MachineInfo {
        MachineInfo(
            chip: sysctlString("machdep.cpu.brand_string") ?? "unknown",
            ramGB: Int((sysctlInt("hw.memsize") ?? 0) / (1 << 30)),
            macOS: ProcessInfo.processInfo.operatingSystemVersionString,
            swift: swiftVersion(),
            packageVersions: resolvedVersions()
        )
    }

    static func slug(_ text: String) -> String {
        let mapped = text.lowercased().map { $0.isLetter || $0.isNumber ? $0 : Character("-") }
        return String(mapped).split(separator: "-").joined(separator: "-")
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func sysctlInt(_ name: String) -> UInt64? {
        var value: UInt64 = 0
        var size = MemoryLayout<UInt64>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    private static func swiftVersion() -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["swift", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "unknown" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").first.map(String.init) ?? "unknown"
    }

    private static func resolvedVersions() -> [String: String] {
        struct Resolved: Decodable {
            struct Pin: Decodable {
                struct State: Decodable { let version: String? }
                let identity: String
                let state: State
            }
            let pins: [Pin]
        }
        var roots = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        if let executable = Bundle.main.executableURL {
            roots.append(executable.deletingLastPathComponent())
        }
        for root in roots {
            var directory = root
            for _ in 0..<6 {
                let candidate = directory.appendingPathComponent("Package.resolved")
                if let data = try? Data(contentsOf: candidate),
                   let resolved = try? JSONDecoder().decode(Resolved.self, from: data) {
                    var versions: [String: String] = [:]
                    for pin in resolved.pins {
                        if let version = pin.state.version { versions[pin.identity] = version }
                    }
                    return versions
                }
                directory.deleteLastPathComponent()
            }
        }
        return [:]
    }
}
