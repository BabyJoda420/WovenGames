// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "woven",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "woven", targets: ["woven"]),
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
        .testTarget(name: "WovenCoreTests", dependencies: ["WovenCore"]),
    ]
)
