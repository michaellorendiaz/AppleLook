// swift-tools-version:6.0
import PackageDescription

let v5: [SwiftSetting] = [.swiftLanguageMode(.v5)]

let package = Package(
    name: "AppleLook",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "AppleLook", targets: ["AppleLook"]),
        .executable(name: "applelook-cli", targets: ["applelook-cli"]),
    ],
    targets: [
        // Feed parsing, recurrence expansion, filtering and sync planning. No EventKit, no UI.
        .target(name: "AppleLookCore", swiftSettings: v5),
        // The menu-bar app. scripts/build-app.sh wraps it into AppleLook.app.
        .executableTarget(name: "AppleLook", dependencies: ["AppleLookCore"], swiftSettings: v5),
        // Developer tool: list what a feed would sync, without touching any calendar.
        .executableTarget(name: "applelook-cli", dependencies: ["AppleLookCore"], swiftSettings: v5),
        .testTarget(name: "AppleLookCoreTests", dependencies: ["AppleLookCore"], swiftSettings: v5),
    ]
)
