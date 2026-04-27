// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ZwiftClick",
    platforms: [.macOS(.v13)],
    dependencies: [
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", from: "1.8.0"),
    ],
    targets: [
        .executableTarget(
            name: "ZwiftClick",
            dependencies: ["CryptoSwift"],
            path: "Sources/ZwiftClick",
            linkerSettings: [
                .linkedFramework("CoreBluetooth"),
                .linkedFramework("ApplicationServices"),
            ]
        )
    ]
)
