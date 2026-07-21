// swift-tools-version: 6.4
import PackageDescription

let coreSwiftSettings: [SwiftSetting] = [
    .swiftLanguageMode(.v6),
    .treatAllWarnings(as: .error),
]

let package = Package(
    name: "UsageCore",
    platforms: [.macOS(.v27)],
    products: [
        .library(name: "UsageKit", targets: ["UsageKit"]),
        .executable(name: "usage", targets: ["UsageCLI"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-argument-parser", exact: "1.8.2")
    ],
    targets: [
        .target(
            name: "UsageKit",
            swiftSettings: coreSwiftSettings
        ),
        .executableTarget(
            name: "UsageCLI",
            dependencies: [
                "UsageKit",
                .product(name: "ArgumentParser", package: "swift-argument-parser"),
            ],
            swiftSettings: coreSwiftSettings
        ),
        .testTarget(
            name: "UsageKitTests",
            dependencies: ["UsageKit"],
            resources: [.copy("Fixtures")],
            swiftSettings: coreSwiftSettings
        ),
        .testTarget(
            name: "UsageCLITests",
            dependencies: ["UsageCLI", "UsageKit"],
            swiftSettings: coreSwiftSettings
        ),
    ]
)
