// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "Delta",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "Delta", targets: ["Delta"]),
        .executable(name: "DeltaAgent", targets: ["DeltaAgent"]),
        .executable(name: "DeltaSecretBridge", targets: ["DeltaSecretBridge"]),
        .library(name: "DeltaCore", targets: ["DeltaCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.3")
    ],
    targets: [
        .target(
            name: "DeltaCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .executableTarget(
            name: "Delta",
            dependencies: [
                "DeltaCore",
                .product(name: "Sparkle", package: "Sparkle")
            ]
        ),
        .executableTarget(
            name: "DeltaAgent",
            dependencies: ["DeltaCore"]
        ),
        .executableTarget(
            name: "DeltaSecretBridge",
            dependencies: ["DeltaCore"]
        ),
        .testTarget(
            name: "DeltaCoreTests",
            dependencies: ["DeltaCore"]
        )
    ]
)
