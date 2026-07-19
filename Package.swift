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
        .executable(name: "DeltaTimeMachineService", targets: ["DeltaTimeMachineService"]),
        .executable(name: "DeltaTimeMachineHelper", targets: ["DeltaTimeMachineHelper"]),
        .library(name: "DeltaCore", targets: ["DeltaCore"]),
        .library(name: "DeltaTimeMachineIPC", targets: ["DeltaTimeMachineIPC"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.9.4")
    ],
    targets: [
        .target(
            name: "DeltaCore",
            dependencies: [
                "DeltaSecurity",
                "DeltaTimeMachineIPC",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        ),
        .target(name: "DeltaTimeMachineIPC"),
        .target(
            name: "DeltaSecurity",
            publicHeadersPath: "include"
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
        .executableTarget(
            name: "DeltaTimeMachineService",
            dependencies: ["DeltaCore", "DeltaTimeMachineIPC"]
        ),
        .executableTarget(
            name: "DeltaTimeMachineHelper",
            dependencies: ["DeltaCore"]
        ),
        .testTarget(
            name: "DeltaCoreTests",
            dependencies: [
                "DeltaCore",
                "DeltaTimeMachineIPC",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
