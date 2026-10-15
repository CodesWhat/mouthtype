import Foundation
import FluidAudio

public enum EngineCatalogError: Error, LocalizedError, Equatable {
    case unknownEngine(id: String, validIDs: [String])

    public var errorDescription: String? {
        switch self {
        case let .unknownEngine(id, validIDs):
            return "Unknown engine '\(id)'. Valid ids: \(validIDs.joined(separator: ", "))"
        }
    }
}

public enum EngineCatalog {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let displayName: String
    }

    public static var ids: [String] { entries.map(\.id) }

    public static var entries: [Entry] {
        factories.map { Entry(id: $0.id, displayName: $0.displayName) }
    }

    public static func make(id: String, englishHint: Bool = false) throws -> any Transcriber {
        guard let factory = factories.first(where: { $0.id == id }) else {
            throw EngineCatalogError.unknownEngine(id: id, validIDs: ids)
        }
        return factory.make(englishHint ? .english : nil)
    }

    private struct Factory {
        let id: String
        let displayName: String
        let make: @Sendable (Language?) -> any Transcriber
    }

    private static let factories: [Factory] = [
        Factory(id: ParakeetEngine.v3ID, displayName: ParakeetEngine.v3DisplayName) { ParakeetEngine(version: .v3, language: $0) },
        Factory(id: ParakeetEngine.v2ID, displayName: ParakeetEngine.v2DisplayName) { ParakeetEngine(version: .v2, language: $0) },
        Factory(id: WhisperEngine.turboID, displayName: WhisperEngine.turboDisplayName) { _ in
            WhisperEngine(id: WhisperEngine.turboID, displayName: WhisperEngine.turboDisplayName, variant: WhisperEngine.turboVariant)
        },
        Factory(id: WhisperEngine.smallEnID, displayName: WhisperEngine.smallEnDisplayName) { _ in
            WhisperEngine(id: WhisperEngine.smallEnID, displayName: WhisperEngine.smallEnDisplayName, variant: WhisperEngine.smallEnVariant)
        },
    ]
}
