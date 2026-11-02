// swift-tools-version: 6.2
import PackageDescription

/// A dynamic library so AetherEngine and its AetherLib* frameworks link into an
/// image of their own, apart from KSPlayer's Libav* frameworks in Lume's.
/// Library evolution keeps the Aether C modules out of Lume's compile; SwiftPM
/// accepts the unsafe flag because Lume consumes this package by path.
let package = Package(
    name: "LumeAetherBridge",
    platforms: [
        .iOS(.v18),
        .tvOS(.v18),
        .macOS(.v15)
    ],
    products: [
        .library(name: "LumeAetherBridge", type: .dynamic, targets: ["LumeAetherBridge"])
    ],
    dependencies: [
        .package(url: "https://github.com/superuser404notfound/AetherEngine", exact: "7.53.1")
    ],
    targets: [
        .target(
            name: "LumeAetherBridge",
            dependencies: [
                .product(name: "AetherEngine", package: "AetherEngine")
            ],
            swiftSettings: [
                .unsafeFlags(["-enable-library-evolution"]),
                .defaultIsolation(MainActor.self)
            ]
        )
    ]
)
