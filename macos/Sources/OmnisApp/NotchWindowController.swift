import AppKit
import Combine
import OmnisCore
import SwiftUI

/// A panel that can take typing (for the ask box) without making OMNIS the front app.
private final class NotchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Tells the model when the pointer comes and goes.
private final class HoverView: NSView {
    var entered: (() -> Void)?
    var left: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let fresh = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self)
        addTrackingArea(fresh)
        area = fresh
    }

    override func mouseEntered(with event: NSEvent) { entered?() }
    override func mouseExited(with event: NSEvent) { left?() }
}

/// Owns the panel at the MacBook's notch. It is an overlay drawn by OMNIS,
/// not a change to the notch itself. It lives only on the built-in screen,
/// and does not appear over full-screen apps.
@MainActor
final class NotchWindowController {
    private let model: NotchModel
    private let panel: NotchPanel
    private var geometry: NotchGeometry?
    private var watching: Set<AnyCancellable> = []
    static let openWidth = 460.0

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        // On every ordinary desktop, but not over an app that has gone full screen.
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        panel.setAccessibilityLabel("OMNIS notch panel")

        place()
        model.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.resize() }
        }.store(in: &watching)
        NotificationCenter.default.publisher(for: NSApplication.didChangeScreenParametersNotification).sink { [weak self] _ in
            Task { @MainActor in self?.place() }
        }.store(in: &watching)
    }

    /// True when there is a built-in screen for the panel to live on.
    var isAvailable: Bool { geometry != nil }

    private static func builtInScreen() -> NSScreen? {
        NSScreen.screens.first { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return false }
            return CGDisplayIsBuiltin(CGDirectDisplayID(number.uint32Value)) != 0
        }
    }

    /// Finds the built-in screen and its notch, and puts the panel there. With the lid shut there is nowhere to put it.
    private func place() {
        guard let screen = Self.builtInScreen() else {
            geometry = nil
            panel.orderOut(nil)
            return
        }
        let frame = screen.frame
        let left = screen.auxiliaryTopLeftArea?.width ?? 0, right = screen.auxiliaryTopRightArea?.width ?? 0
        let hasNotch = screen.safeAreaInsets.top > 0 && left > 0 && right > 0
        let found = NotchGeometry(
            screen: NotchGeometry.Rect(x: frame.minX, y: frame.minY, width: frame.width, height: frame.height),
            notchWidth: hasNotch ? frame.width - left - right : 0,
            notchHeight: hasNotch ? screen.safeAreaInsets.top : 0)
        if found != geometry || panel.contentView == nil {
            geometry = found
            let hover = HoverView()
            hover.entered = { [weak self] in self?.model.pointerEntered() }
            hover.left = { [weak self] in self?.model.pointerLeft() }
            let host = NSHostingView(rootView: NotchView(model: model, notchHeight: max(found.notchHeight, 24),
                                                         notchWidth: max(found.notchWidth, 180)))
            host.translatesAutoresizingMaskIntoConstraints = false
            hover.addSubview(host)
            NSLayoutConstraint.activate([host.leadingAnchor.constraint(equalTo: hover.leadingAnchor), host.trailingAnchor.constraint(equalTo: hover.trailingAnchor),
                                         host.topAnchor.constraint(equalTo: hover.topAnchor), host.bottomAnchor.constraint(equalTo: hover.bottomAnchor)])
            panel.contentView = hover
        }
        resize()
        panel.orderFrontRegardless()
    }

    /// How tall the open panel needs to be for what it is showing.
    private var openHeight: Double {
        switch model.showing {
        case .nothing: return 0
        case .voice:
            guard let answer = model.waitingAnswer else { return 124 }
            let cards = (answer.searchAsk?.state == .waiting ? 1 : 0) + min(2, answer.actions.filter { $0.state == .waiting }.count)
                + min(2, answer.proposals.filter { $0.state == .waiting }.count)
            let lines = answer.actions.filter { $0.state == .waiting }.prefix(2).reduce(0) { total, action in
                // A long message wraps: allow a line for every forty-five characters.
                total + action.rows.reduce(0) { $0 + max(1, ($1.value.count + $1.label.count) / 45 + $1.value.filter { $0 == "\n" }.count + 1) }
            }
            return 136 + Double(cards) * 96 + Double(lines) * 17
        case .everyday:
            return 196 + (model.reminders.isEmpty ? 0 : 24) + (model.track != nil || model.musicNote != nil ? 24 : 0)
                + (model.dashboard.tiles.isEmpty ? 0 : 36)
        }
    }

    private func resize() {
        guard let geometry else { return }
        let rect = model.isOpen ? geometry.open(width: Self.openWidth, height: openHeight) : geometry.resting
        let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        // Typing in the ask box needs the panel to take the keyboard; otherwise it never does.
        if model.showing == .everyday, !panel.isKeyWindow, model.typing { panel.makeKey() }
    }
}
