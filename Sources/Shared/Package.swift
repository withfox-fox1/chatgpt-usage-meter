// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ChatGPTUsageCore",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(
            name: "ChatGPTUsageCore",
            targets: ["ChatGPTUsageCore"]
        )
    ],
    targets: [
        .target(
            name: "ChatGPTUsageCore"
        ),
        .testTarget(
            name: "ChatGPTUsageCoreTests",
            dependencies: ["ChatGPTUsageCore"]
        )
    ]
)
