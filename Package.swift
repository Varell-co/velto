// swift-tools-version: 5.9
import PackageDescription

// The app and the CLI need different target names: macOS file systems ignore case, so "Velto" and
// "velto" would land on the same path in the build folder.
let package = Package(
    name: "Velto",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "VeltoApp", targets: ["VeltoApp"]),
        .executable(name: "velto", targets: ["velto"]),
    ],
    targets: [
        .target(name: "VeltoCore"),
        .executableTarget(name: "VeltoApp", dependencies: ["VeltoCore"]),
        .executableTarget(name: "velto", dependencies: ["VeltoCore"], path: "Sources/VeltoCLI"),
        .executableTarget(name: "VeltoChecks", dependencies: ["VeltoCore"], path: "Checks"),
    ]
)
