// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Mouthtype",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "MouthtypeCore", targets: ["MouthtypeCore"]),
        .executable(name: "mouthtype-bench", targets: ["mouthtype-bench"]),
    ],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", from: "0.17.7"),
        .package(url: "https://github.com/argmaxinc/WhisperKit", from: "1.1.1"),
        .package(url: "https://github.com/apple/swift-argument-parser", from: "1.8.2"),
    ],
    targets: [
        .target(
            name: "MouthtypeCore",
            dependencies: [
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "WhisperKit", package: "WhisperKit"),
            ]
        ),
        .executableTarget(
            name: "mouthtype-bench",
            dependencies: [
                "MouthtypeCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .testTarget(
            name: "MouthtypeCoreTests",
            dependencies: ["MouthtypeCore"]
        ),
    ]
)
