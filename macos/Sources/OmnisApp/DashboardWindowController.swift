import AppKit
import SwiftUI

/// Owns the dashboard, OMNIS's main window. It is an ordinary window: it has
/// a place in the Dock and the Window menu, and closing it leaves OMNIS running.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: DashboardModel
    private let window: NSWindow

    init(model: DashboardModel, chat: ChatModel) {
        self.model = model
        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1360, height: 880),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init()
        window.title = "OMNIS"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isMovableByWindowBackground = true
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.024, green: 0.031, blue: 0.043, alpha: 1)
        window.minSize = NSSize(width: 1060, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model, chat: chat))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("OMNISDashboard")
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        model.windowOpened()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        model.windowClosed()
    }

    func windowDidMiniaturize(_ notification: Notification) {
        model.windowClosed()
    }

    func windowDidDeminiaturize(_ notification: Notification) {
        model.windowOpened()
    }
}
