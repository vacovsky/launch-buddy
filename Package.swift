// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "LaunchBuddy",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "LaunchBuddy",
            exclude: ["Info.plist", "AppIcon.icns"]
        ),
        .testTarget(
            name: "LaunchBuddyTests",
            dependencies: ["LaunchBuddy"]
        )
    ]
)
