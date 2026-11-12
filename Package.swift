// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "nextclick",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "NextClick", targets: ["NextClick"]),
    ],
    targets: [
        .target(name: "NextClick", path: "Sources/NextClick"),
        .testTarget(name: "NextClickTests", dependencies: ["NextClick"]),
    ]
)
