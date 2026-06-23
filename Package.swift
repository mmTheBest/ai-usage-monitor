// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AIUsageMonitor",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "AIUsageCore", targets: ["AIUsageCore"]),
        .executable(name: "AIUsageMonitor", targets: ["AIUsageMonitor"])
    ],
    targets: [
        .target(name: "AIUsageCore"),
        .executableTarget(
            name: "AIUsageMonitor",
            dependencies: ["AIUsageCore"]
        )
    ]
)
