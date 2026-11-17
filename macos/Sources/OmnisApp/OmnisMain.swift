import AppKit

/// Entry point. The app has a Dock icon and a menu-bar icon; its only window
/// is the popup panel.
@main
@MainActor
enum OmnisMain {
    // Kept alive for the life of the app; NSApplication holds its delegate weakly.
    private static let delegate = AppDelegate()

    static func main() {
        let application = NSApplication.shared
        application.delegate = delegate
        application.setActivationPolicy(.regular)
        application.run()
    }
}
