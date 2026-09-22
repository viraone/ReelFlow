// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ReelFlow",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "ReelFlow", targets: ["ReelFlow"])],
    targets: [
        .executableTarget(
            name: "ReelFlow",
            path: "Sources/ReelFlow",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ReelFlowTests",
            dependencies: ["ReelFlow"],
            path: "Tests/ReelFlowTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
