// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "TaskTick",
    defaultLocalization: "en",
    platforms: [
        .macOS(.v15)
    ],
    targets: [
        .executableTarget(
            name: "TaskTick",
            path: "Sources",
            resources: [
                .process("Localization")
            ]
        ),
        .testTarget(
            name: "TaskTickTests",
            dependencies: ["TaskTick"],
            path: "Tests"
        )
    ]
)
