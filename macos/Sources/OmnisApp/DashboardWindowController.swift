import AppKit
import SwiftUI

/// Owns the dashboard, OMNIS's main window. It is an ordinary window: it has
/// a place in the Dock and the Window menu, and closing it leaves OMNIS running.
@MainActor
final class DashboardWindowController: NSObject, NSWindowDelegate {
    private let model: DashboardModel
    private let project: ProjectModeModel
    private let window: NSWindow

    init(model: DashboardModel, chat: ChatModel, project: ProjectModeModel, voice: VoiceModel) {
        self.model = model
        self.project = project
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
        // Not movable by its background: dragging in a terminal selects text.
        window.isMovableByWindowBackground = false
        window.appearance = NSAppearance(named: .darkAqua)
        window.backgroundColor = NSColor(red: 0.024, green: 0.031, blue: 0.043, alpha: 1)
        window.minSize = NSSize(width: 1120, height: 680)
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: DashboardView(model: model, chat: chat, project: project, voice: voice))
        window.delegate = self
        window.center()
        window.setFrameAutosaveName("OMNISDashboard")
    }

    var isVisible: Bool { window.isVisible }

    func show() {
        if window.isMiniaturized { window.deminiaturize(nil) }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        update()
    }

    /// Tells the model whether the window can actually be seen. macOS reports
    /// a change whenever it is covered, uncovered, minimised, closed or moved
    /// to a desktop that is not showing.
    private func update() {
        let seen = window.isVisible && !window.isMiniaturized && window.occlusionState.contains(.visible)
        model.setOnScreen(seen)
        project.setOnScreen(seen)
    }

    func windowDidChangeOcclusionState(_ notification: Notification) { update() }
    func windowWillClose(_ notification: Notification) {
        model.setOnScreen(false)
        project.setOnScreen(false)
    }
    func windowDidMiniaturize(_ notification: Notification) { update() }
    func windowDidDeminiaturize(_ notification: Notification) { update() }
}
