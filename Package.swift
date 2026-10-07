// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DictationApp",
    platforms: [.macOS("26.0")],
    targets: [
        // All app code lives in the library so tests can import it.
        .target(
            name: "DictationKit",
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
