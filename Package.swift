// swift-tools-version: 5.10
import PackageDescription

// JarvisCore holds everything that is not tied to iPadOS frameworks:
// the tool registry, the safety engine, the confirmation engine, the
// Claude client and the agent loop. It is kept platform-neutral so the
// same core can later power the Mac companion and is unit-testable with
// `swift test` on any machine.
let package = Package(
    name: "JarvisCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "JarvisCore", targets: ["JarvisCore"]),
    ],
    targets: [
        .target(name: "JarvisCore"),
        .testTarget(name: "JarvisCoreTests", dependencies: ["JarvisCore"]),
    ]
)
