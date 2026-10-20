// swift-tools-version: 6.0
// RhythmCore: all game logic for Sound Vision. Foundation + simd only.
// Do not add RealityKit, SwiftUI or AVFoundation dependencies here (see docs/DECISIONS.md).
import PackageDescription

let package = Package(
    name: "RhythmCore",
    platforms: [.macOS(.v15), .visionOS(.v2)],
    products: [
        .library(name: "RhythmCore", targets: ["RhythmCore"]),
    ],
    targets: [
        .target(name: "RhythmCore"),
        .testTarget(name: "RhythmCoreTests", dependencies: ["RhythmCore"]),
    ]
)
