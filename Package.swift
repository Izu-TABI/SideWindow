// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "SideWindow",
    platforms: [.macOS("15.2")],
    targets: [
        .executableTarget(
            name: "SideWindow",
            path: "Sources/SideWindow"
        ),
        .testTarget(
            name: "SideWindowTests",
            dependencies: ["SideWindow"],
            path: "Tests/SideWindowTests"
        ),
    ]
)
