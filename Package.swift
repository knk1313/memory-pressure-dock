// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "MemoryPressureDock",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "MemoryPressureDock",
            path: "Sources/MemoryPressureDock",
            linkerSettings: [.linkedFramework("CoreWLAN")]
        ),
        .testTarget(
            name: "MemoryPressureDockTests",
            dependencies: ["MemoryPressureDock"],
            path: "Tests/MemoryPressureDockTests"
        ),
    ],
    swiftLanguageModes: [.v5]
)
