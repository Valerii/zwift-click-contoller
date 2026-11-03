// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ZwiftClickV2",
    platforms: [.macOS(.v13)],
    dependencies: [
        // AES-CCM for the Click v1's encrypted protocol (CryptoKit has no CCM). Same library as v1.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
    ],
    targets: [
        .target(
            name: "ZwiftClickV2Core",
            dependencies: ["CryptoSwift"],
            path: "Sources/ZwiftClickV2Core",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("AppKit"),
            ]
        ),
        .executableTarget(
            name: "ZwiftClickV2",
            dependencies: ["ZwiftClickV2Core"],
            path: "Sources/ZwiftClickV2"
        ),
        .testTarget(
            name: "ZwiftClickV2Tests",
            dependencies: ["ZwiftClickV2Core", "CryptoSwift"],
            path: "Tests/ZwiftClickV2Tests"
        ),
    ]
)
