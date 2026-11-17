// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Omnis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OmnisCore", targets: ["OmnisCore"]),
        .executable(name: "OmnisApp", targets: ["OmnisApp"]),
    ],
    targets: [
        // Everything that can be tested without a window: matching, registry,
        // launching, the backend protocol and its supervisor.
        .target(name: "OmnisCore"),
        // The popup, hotkey, menu-bar item and Dock presence.
        .executableTarget(name: "OmnisApp", dependencies: ["OmnisCore"]),
        .testTarget(name: "OmnisCoreTests", dependencies: ["OmnisCore"]),
    ],
    swiftLanguageModes: [.v5]
)
