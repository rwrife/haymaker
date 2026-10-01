// swift-tools-version:6.0
import PackageDescription

// HaymakerStore — persistence layer for Haymaker (GRDB/SQLite stub in M1).
// Pure domain storage package, Linux-testable by design.
let package = Package(
    name: "HaymakerStore",
    platforms: [
        .iOS("26.0"),
    ],
    products: [
        .library(name: "HaymakerStore", targets: ["HaymakerStore"]),
    ],
    dependencies: [
        .package(path: "../HaymakerKit"),
    ],
    targets: [
        .target(name: "HaymakerStore", dependencies: ["HaymakerKit"]),
        .testTarget(name: "HaymakerStoreTests", dependencies: ["HaymakerStore"]),
    ]
)
