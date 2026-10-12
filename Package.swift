// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "Mouthtype",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "MouthtypeCore", targets: ["MouthtypeCore"]),
        .executable(name: "mouthtype-bench", targets: ["mouthtype-bench"]),
        .executable(name: "Mouthtype", targets: ["Mouthtype"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "3.32.3", traits: []),
        .package(url: "https://github.com/huggingface/swift-huggingface", from: "1.0.0"),
        .package(url: "https://github.com/huggingface/swift-transformers", from: "1.3.5"),
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .target(
            name: "MouthtypeCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
                .product(name: "Tokenizers", package: "swift-transformers"),
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "MouthtypeMac",
            dependencies: ["MouthtypeCore"],
            resources: [.copy("Resources/Pill"), .copy("Resources/MenuBar"), .copy("Resources/Fonts")]
        ),
        .executableTarget(
            name: "Mouthtype",
            dependencies: ["MouthtypeMac"]
        ),
        .executableTarget(
            name: "mouthtype-bench",
            dependencies: [
                "MouthtypeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            resources: [.copy("Fixtures/cleanup-cases.json")]
        ),
        .testTarget(
            name: "MouthtypeCoreTests",
            dependencies: ["MouthtypeCore", "mouthtype-bench"]
        ),
        .testTarget(
            name: "MouthtypeMacTests",
            dependencies: ["MouthtypeMac"]
        ),
    ]
)
