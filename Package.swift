// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Infinite Remote",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .executable(name: "RemoteDesk", targets: ["RemoteDesk"])
    ],
    dependencies: [
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.1")
    ],
    targets: [
        .target(name: "RemoteCore"),
        .executableTarget(name: "RemoteDesk", dependencies: [
            "RemoteCore",
            .product(name: "Sparkle", package: "Sparkle")
        ], resources: [
            .process("Resources/CommandBridge.xcassets"),
            .process("Resources/Localization"),
            .copy("Resources/LICENSE-Tabler.txt")
        ]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteDeskTests", dependencies: ["RemoteDesk", "RemoteCore"], resources: [.copy("Fixtures")])
    ]
)
