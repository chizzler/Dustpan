// swift-tools-version: 6.2
import PackageDescription

let settings: [SwiftSetting] = [
    .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
]

let package = Package(
    name: "DustpanCore",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "DustpanCore", targets: ["DustpanCore"]),
        .executable(name: "dustpan-cli", targets: ["dustpan-cli"]),
    ],
    targets: [
        .target(name: "DustpanCore", resources: [.copy("Resources/vocab.json")], swiftSettings: settings,
                linkerSettings: [.linkedLibrary("sqlite3")]),
        .executableTarget(name: "dustpan-cli", dependencies: ["DustpanCore"], swiftSettings: settings),
        .testTarget(name: "DustpanCoreTests", dependencies: ["DustpanCore"], swiftSettings: settings),
    ]
)
