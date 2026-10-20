// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationApp",
    platforms: [.macOS("26.0")],
    dependencies: [
        // The On-device setup's speech model (Qwen3-ASR on MLX). Pinned: MLX model code changes often.
        .package(url: "https://github.com/Blaizzy/mlx-audio-swift", revision: "244458d"),
        .package(url: "https://github.com/ml-explore/mlx-swift.git", .upToNextMajor(from: "0.30.6")),
        .package(url: "https://github.com/huggingface/swift-huggingface.git", .upToNextMajor(from: "0.8.1")),
    ],
    targets: [
        // All app code lives in the library so tests can import it.
        .target(
            name: "DictationKit",
            dependencies: [
                .product(name: "MLXAudioSTT", package: "mlx-audio-swift"),
                .product(name: "MLXAudioCore", package: "mlx-audio-swift"),
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "HuggingFace", package: "swift-huggingface"),
            ],
            // Command mode's example commands, copied into the commands folder the first time.
            resources: [.copy("ExampleCommands")],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [
                // Apple Intelligence is optional at runtime (AI polish falls back to raw text).
                .unsafeFlags(["-Xlinker", "-weak_framework", "-Xlinker", "FoundationModels"]),
            ]
        ),
        .executableTarget(
            name: "DictationApp",
            dependencies: ["DictationKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "DictationKitTests",
            dependencies: ["DictationKit"],
            exclude: ["__Snapshots__"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
