// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Omnis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OmnisCore", targets: ["OmnisCore"]),
        .executable(name: "OmnisApp", targets: ["OmnisApp"]),
    ],
    dependencies: [
        // A terminal view, used only for the Claude Code terminals in project
        // mode. MIT licence. Drawing a terminal correctly is a large job that
        // is not worth redoing.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0"),
    ],
    targets: [
        // Everything that can be tested without a window: matching, registry,
        // launching, the backend protocol and its supervisor.
        .target(name: "OmnisCore"),
        // The popup, hotkey, menu-bar item and Dock presence.
        .executableTarget(name: "OmnisApp", dependencies: ["OmnisCore", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "OmnisCoreTests", dependencies: ["OmnisCore"]),
    ],
    swiftLanguageModes: [.v5]
)
