// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "woven",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "woven", targets: ["woven"]),
        .executable(name: "WovenGames", targets: ["WovenGames"]),
        .library(name: "WovenCore", targets: ["WovenCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.5.0"),
    ],
    targets: [
        .target(name: "WovenCore"),
        .executableTarget(
            name: "woven",
            dependencies: [
                "WovenCore",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ]
        ),
        .executableTarget(name: "WovenGames", dependencies: ["WovenCore"], path: "Sources/WovenGamesApp"),
        .testTarget(name: "WovenCoreTests", dependencies: ["WovenCore"]),
    ]
)
