// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Lunchpad",
    defaultLocalization: "en",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Lunchpad",
            dependencies: ["MultitouchKit", "ApplicationMonitorKit", "DesktopStateKit"],
            path: "Sources/Lunchpad",
            resources: [.process("Resources")]
        ),
        .target(name: "MultitouchKit", path: "Sources/MultitouchKit"),
        .target(name: "ApplicationMonitorKit", path: "Sources/ApplicationMonitorKit"),
        .target(name: "DesktopStateKit", path: "Sources/DesktopStateKit"),
    ],
    swiftLanguageModes: [.v6]
)
