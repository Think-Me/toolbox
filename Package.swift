// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Toolbox",
    platforms: [.macOS(.v14)],
    targets: [
        // 库 target：全部可测试逻辑。SwiftPM 的 test target 不能 import executable target，
        // 所以逻辑必须放这里，否则单测一行都跑不了。
        .target(name: "ToolboxKit", swiftSettings: [.swiftLanguageMode(.v6)]),
        // 可执行 target：只有入口，不含逻辑。
        .executableTarget(name: "Toolbox", dependencies: ["ToolboxKit"],
                          swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "ToolboxKitTests", dependencies: ["ToolboxKit"],
                    swiftSettings: [.swiftLanguageMode(.v6)]),
    ]
)
