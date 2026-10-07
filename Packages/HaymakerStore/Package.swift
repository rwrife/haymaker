// swift-tools-version:6.0
import PackageDescription

// Local append-only persistence.
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
        .package(url: "https://github.com/groue/GRDB.swift.git", exact: "7.8.0"),
    ],
    targets: [
        .target(name: "HaymakerStore", dependencies: ["HaymakerKit", .product(name: "GRDB", package: "GRDB.swift")]),
        .testTarget(name: "HaymakerStoreTests", dependencies: ["HaymakerStore", .product(name: "GRDB", package: "GRDB.swift")], resources: [.copy("Fixtures")]),
    ]
)
