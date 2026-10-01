// swift-tools-version:6.0
import PackageDescription

// HaymakerKit — pure-domain match engine for Haymaker.
// No UI, no networking, no Apple-only frameworks (no UIKit/SpriteKit imports):
// Linux-testable by design. Fight outcomes are a pure function of
// (seed, player inputs).
let package = Package(
    name: "HaymakerKit",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "HaymakerKit", targets: ["HaymakerKit"]),
    ],
    targets: [
        .target(name: "HaymakerKit"),
        .testTarget(name: "HaymakerKitTests", dependencies: ["HaymakerKit"]),
    ]
)
