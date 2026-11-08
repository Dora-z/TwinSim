// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TwinSim",
    platforms: [.macOS(.v15)],
    products: [.executable(name: "twinsimd", targets: ["TwinSim"])],
    dependencies: [.package(url: "https://github.com/vapor/vapor.git", exact: "4.122.3")],
    targets: [.executableTarget(name: "TwinSim", dependencies: [.product(name: "Vapor", package: "vapor")])],
    swiftLanguageModes: [.v5]
)
