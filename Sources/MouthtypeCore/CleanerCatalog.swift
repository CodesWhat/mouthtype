import Foundation

public enum CleanerCatalogError: Error, LocalizedError, Equatable {
    case unknownCleaner(id: String, validIDs: [String])

    public var errorDescription: String? {
        switch self {
        case let .unknownCleaner(id, validIDs):
            return "Unknown cleaner '\(id)'. Valid ids: \(validIDs.joined(separator: ", "))"
        }
    }
}

public enum CleanerCatalog {
    public struct Entry: Sendable, Equatable {
        public let id: String
        public let displayName: String
    }

    public static var ids: [String] { entries.map(\.id) }

    public static var entries: [Entry] {
        factories.map { Entry(id: $0.id, displayName: $0.displayName) }
    }

    public static func make(id: String) throws -> any MeasuredCleaner {
        guard let factory = factories.first(where: { $0.id == id }) else {
            throw CleanerCatalogError.unknownCleaner(id: id, validIDs: ids)
        }
        return factory.make()
    }

    private struct Factory {
        let id: String
        let displayName: String
        let make: @Sendable () -> any MeasuredCleaner
    }

    private static let mlxSpecs: [MLXCleaner.Spec] = [
        MLXCleaner.Spec(
            id: "gemma-4-e2b-it-4bit", displayName: "Gemma 4 E2B it (MLX 4-bit)",
            repo: "mlx-community/gemma-4-e2b-it-4bit", quantization: "4-bit", promptFormat: .shared, license: nil),
        MLXCleaner.Spec(
            id: "gemma-4-e4b-it-4bit", displayName: "Gemma 4 E4B it (MLX 4-bit)",
            repo: "mlx-community/gemma-4-e4b-it-4bit", quantization: "4-bit", promptFormat: .shared, license: "Gemma Terms of Use",
            downloadSizeMB: 5150),
        MLXCleaner.Spec(
            id: "qwen3-4b-instruct-2507-4bit", displayName: "Qwen3 4B Instruct 2507 (MLX 4-bit)",
            repo: "mlx-community/Qwen3-4B-Instruct-2507-4bit", quantization: "4-bit", promptFormat: .shared, license: nil),
        MLXCleaner.Spec(
            id: "llama-3.2-3b-instruct-4bit", displayName: "Llama 3.2 3B Instruct (MLX 4-bit)",
            repo: "mlx-community/Llama-3.2-3B-Instruct-4bit", quantization: "4-bit", promptFormat: .shared, license: nil),
        MLXCleaner.Spec(
            id: "phi-4-mini-instruct-4bit", displayName: "Phi-4-mini Instruct (MLX 4-bit)",
            repo: "mlx-community/Phi-4-mini-instruct-4bit", quantization: "4-bit", promptFormat: .shared, license: nil),
        MLXCleaner.Spec(
            id: "superwhisper-s1-mini", displayName: "Superwhisper S1-mini (BF16, native prompt)",
            repo: "superwhisper/s1-mini", quantization: "bf16", promptFormat: .s1Mini,
            license: "Apache 2.0 plus a naming clause (the model must keep the name \"S1-mini\" by \"Superwhisper\")",
            downloadSizeMB: 1447),
    ]

    /// The model the app's smart cleanup runs. Wherever it is named in the UI it reads exactly this.
    public static let smartCleanupID = "gemma-4-e4b-it-4bit"
    public static let smartCleanupName = "Gemma 4 E4B"

    public static func makeSmartCleanup() -> MLXCleaner {
        guard let spec = mlxSpec(id: smartCleanupID) else { preconditionFailure("Smart cleanup model is missing from the catalog") }
        return MLXCleaner(spec: spec)
    }

    public static func mlxSpec(id: String) -> MLXCleaner.Spec? {
        mlxSpecs.first { $0.id == id }
    }

    private static let factories: [Factory] =
        mlxSpecs.map { spec in
            Factory(id: spec.id, displayName: spec.displayName) { MLXCleaner(spec: spec) }
        } + [
            Factory(id: AppleCleaner.modelID, displayName: AppleCleaner.modelDisplayName) { AppleCleaner() },
            Factory(id: ClaudeCLICleaner.haikuID, displayName: ClaudeCLICleaner.haikuDisplayName) {
                ClaudeCLICleaner(id: ClaudeCLICleaner.haikuID, displayName: ClaudeCLICleaner.haikuDisplayName, model: "haiku")
            },
        ]
}
