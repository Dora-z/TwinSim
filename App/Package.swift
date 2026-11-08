// swift-tools-version: 6.0
import PackageDescription

// TwinSim macOS frontend. The backend (`twinsimd`) is built by the package at the repository root
// and copied into the application bundle by scripts/package-app.sh.
let package = Package(
    name: "TwinSimApp",
    platforms: [.macOS(.v15)],
    products: [
        .executable(name: "TwinSim", targets: ["TwinSimApp"]),
        // AI integration: MCP server, JSON CLI and function-calling schema export.
        // Built as `twinsimctl` (the volume is case-insensitive next to `TwinSim`); installed in
        // the bundle as Contents/Helpers/twinsim.
        .executable(name: "twinsimctl", targets: ["twinsimctl"]),
    ],
    targets: [
        .target(name: "TwinSimAgentProtocol", path: "Sources/TwinSimAgentProtocol"),
        .executableTarget(name: "twinsimctl", dependencies: ["TwinSimAgentProtocol"], path: "Sources/twinsimctl"),
        .executableTarget(
            name: "TwinSimApp",
            dependencies: ["TwinSimAgentProtocol"],
            path: "Sources/TwinSimApp",
            linkerSettings: [
                .linkedFramework("VideoToolbox"),
                .linkedFramework("CoreMedia"),
                .linkedFramework("UniformTypeIdentifiers"),
            ]
        ),
        .testTarget(name: "TwinSimAppTests", dependencies: ["TwinSimApp"], path: "Tests/TwinSimAppTests"),
        .testTarget(name: "twinsimctlTests", dependencies: ["twinsimctl", "TwinSimAgentProtocol"], path: "Tests/twinsimctlTests"),
    ],
    swiftLanguageModes: [.v5]
)
