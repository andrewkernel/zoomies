// swift-tools-version:6.0
import PackageDescription

// Zoomies — measurement-first tuning for local LLM inference.
//
// ZoomiesKit holds everything that is not UI: hardware probes, GGUF inspection,
// runtime adapters (llama.cpp first), the benchmark runner, statistics and
// the SQLite result store. The `zoomies` CLI and (later) the SwiftUI app are
// thin front ends over it.
let package = Package(
    name: "Zoomies",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZoomiesKit", targets: ["ZoomiesKit"]),
        .executable(name: "zoomies", targets: ["zoomies"]),
    ],
    targets: [
        .target(
            name: "ZoomiesKit",
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .executableTarget(name: "zoomies", dependencies: ["ZoomiesKit"]),
        .testTarget(
            name: "ZoomiesKitTests",
            dependencies: ["ZoomiesKit"],
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v5]
)
