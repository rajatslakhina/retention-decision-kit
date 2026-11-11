// swift-tools-version: 6.0
import PackageDescription

// Library-only package. There is deliberately no executable or app target here:
// the runnable demo lives in its own repository as a real Xcode project that
// consumes these products as a remote package, by released version
// (`upToNextMajorVersion` from 1.0.0).
//
// Platforms are limited to what CI builds: macOS (swift build/test on macos-15)
// and iOS (xcodebuild for the iOS Simulator). Linux is exercised by the
// swift:6.0 container job and needs no declaration here.
let package = Package(
    name: "RetentionDecisionKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        // The hot path: Apple calls it, it answers inside a hard deadline.
        .library(name: "RetentionEngine", targets: ["RetentionEngine"]),
        // The offline AI pipeline: drafts, gates and compiles copy. Never linked by the hot path.
        .library(name: "RetentionCopy", targets: ["RetentionCopy"]),
        // Outcome attribution and the experiment readout.
        .library(name: "RetentionAttribution", targets: ["RetentionAttribution"]),
        // SwiftUI lab used by the demo app (pure scenario logic is platform-agnostic and tested on Linux).
        .library(name: "RetentionLab", targets: ["RetentionLab"]),
    ],
    targets: [
        .target(name: "RetentionEngine"),
        .target(name: "RetentionCopy", dependencies: ["RetentionEngine"]),
        .target(name: "RetentionAttribution", dependencies: ["RetentionEngine"]),
        .target(
            name: "RetentionLab",
            dependencies: ["RetentionEngine", "RetentionCopy", "RetentionAttribution"]
        ),
        .testTarget(name: "RetentionEngineTests", dependencies: ["RetentionEngine"]),
        .testTarget(name: "RetentionCopyTests", dependencies: ["RetentionCopy", "RetentionEngine"]),
        .testTarget(
            name: "RetentionAttributionTests",
            dependencies: ["RetentionAttribution", "RetentionEngine"]
        ),
        .testTarget(
            name: "RetentionLabTests",
            dependencies: ["RetentionLab", "RetentionEngine", "RetentionCopy", "RetentionAttribution"]
        ),
    ]
)
