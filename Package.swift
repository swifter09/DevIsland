// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "DevIsland",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        .executableTarget(
            name: "DevIsland",
            path: "Sources/DevIsland"
        )
    ]
)
