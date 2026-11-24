// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Omnis",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "OmnisCore", targets: ["OmnisCore"]),
        .executable(name: "OmnisApp", targets: ["OmnisApp"]),
        .executable(name: "OmnisMessagesReader", targets: ["OmnisMessagesReader"]),
    ],
    dependencies: [
        // A terminal view, used only for the Claude Code terminals in project
        // mode. MIT licence. Drawing a terminal correctly is a large job that
        // is not worth redoing.
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", exact: "1.99.3"),
    ],
    targets: [
        // Everything that can be tested without a window: matching, registry,
        // launching, the backend protocol and its supervisor.
        .target(name: "OmnisCore", dependencies: ["OmnisHelperLink"]),
        // What OMNIS and its Messages reader say to each other, and how each
        // checks who the other is.
        .target(name: "OmnisHelperLink"),
        // Reads the Messages database. Kept apart from OMNIS: only the small
        // helper program below is built from it.
        .target(name: "MessagesReaderCore", dependencies: ["OmnisHelperLink"]),
        // The helper that is given Full Disk Access instead of OMNIS.
        .executableTarget(name: "OmnisMessagesReader", dependencies: ["MessagesReaderCore"]),
        // The popup, hotkey, menu-bar item and Dock presence.
        .executableTarget(name: "OmnisApp", dependencies: ["OmnisCore", "OmnisHelperLink", .product(name: "SwiftTerm", package: "SwiftTerm")]),
        .testTarget(name: "OmnisCoreTests", dependencies: ["OmnisCore", "OmnisHelperLink", "MessagesReaderCore"]),
    ],
    swiftLanguageModes: [.v5]
)
