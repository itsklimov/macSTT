// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "macSTT",
    platforms: [.macOS(.v15)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-log.git", from: "1.11.0"),
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.13.5"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts.git", from: "2.4.0"),
        .package(url: "https://github.com/sparkle-project/Sparkle.git", from: "2.9.1"),
    ],
    targets: [
        .executableTarget(
            name: "macSTT",
            dependencies: [
                .product(name: "Logging", package: "swift-log"),
                .product(name: "FluidAudio", package: "FluidAudio"),
                .product(name: "KeyboardShortcuts", package: "KeyboardShortcuts"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/macSTT",
            exclude: [
                "Assets.xcassets",
            ]
        ),
        .testTarget(
            name: "macSTTTests",
            dependencies: ["macSTT"],
            path: "Tests"
        ),
    ]
)
