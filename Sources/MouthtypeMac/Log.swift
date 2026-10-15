import os

enum Log {
    static let app = Logger(subsystem: "com.codeswhat.mouthtype", category: "app")
    static let capture = Logger(subsystem: "com.codeswhat.mouthtype", category: "capture")
    static let engine = Logger(subsystem: "com.codeswhat.mouthtype", category: "engine")
    static let cleaner = Logger(subsystem: "com.codeswhat.mouthtype", category: "cleaner")
}
