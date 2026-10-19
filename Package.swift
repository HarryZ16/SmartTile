// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "SmartTile",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SmartTile",
            path: "Sources/SmartTile",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("Carbon"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ServiceManagement"),
            ]
        ),
        // Unit tests for the layout engine: swift test
        .testTarget(
            name: "SmartTileTests",
            dependencies: ["SmartTile"],
            path: "Tests/SmartTileTests"
        ),
    ]
)
