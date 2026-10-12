import os

extension Log {
    static let hotkey = Logger(subsystem: "com.codeswhat.mouthtype", category: "hotkey")
    static let probe = Logger(subsystem: "com.codeswhat.mouthtype", category: "probe")
    static let permissions = Logger(subsystem: "com.codeswhat.mouthtype", category: "permissions")
}

extension Log {
    static let selftest = Logger(subsystem: "com.codeswhat.mouthtype", category: "selftest")
}
