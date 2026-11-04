// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RemoteDesk",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "RemoteCore", targets: ["RemoteCore"]),
        .executable(name: "RemoteDesk", targets: ["RemoteDesk"])
    ],
    targets: [
        .target(name: "RemoteCore"),
        .executableTarget(name: "RemoteDesk", dependencies: ["RemoteCore"], resources: [
            .copy("Resources/XiaomiRemote2Pro.png"),
            .process("Resources/CommandBridge.xcassets"),
            .copy("Resources/LICENSE-Tabler.txt")
        ]),
        .testTarget(name: "RemoteCoreTests", dependencies: ["RemoteCore"]),
        .testTarget(name: "RemoteDeskTests", dependencies: ["RemoteDesk", "RemoteCore"])
    ]
)
