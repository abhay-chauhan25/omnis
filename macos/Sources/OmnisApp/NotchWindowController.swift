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
    private var shrink: Task<Void, Never>?
    private var closing = 0
    private var watching: Set<AnyCancellable> = []
    /// The everyday view is wide, like a shelf; a conversation needs less room.
    private var openWidth: Double { model.showing == .voice ? 540 : 720 }

    init(model: NotchModel) {
        self.model = model
        panel = NotchPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        // It takes the keyboard only for the ask box, never because a button was clicked.
        panel.becomesKeyOnlyIfNeeded = true
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

    /// True when the panel can be seen right now: there is a built-in screen, and the
    /// desktop in front is not an app in full screen, where the panel stays away.
    var isAvailable: Bool { geometry != nil && panel.isOnActiveSpace }

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

    /// How tall the open panel needs to be for what it is showing. Generous for
    /// previews, which scroll inside the panel if they are longer still.
    private var openHeight: Double {
        switch model.showing {
        case .nothing: return 0
        case .voice:
            guard let answer = model.waitingAnswer else { return 142 }
            func lines(_ text: String) -> Double { Double(max(1, text.count / 42 + 1 + text.filter { $0 == "\n" }.count)) }
            var height = 158.0
            if let ask = answer.searchAsk, ask.state == .waiting { height += 88 + lines(ask.query) * 17 }
            for action in answer.actions.filter({ $0.state == .waiting }).prefix(2) {
                height += 82 + lines(action.title) * 18 + action.rows.reduce(0) { $0 + lines("\($1.label): \($1.value)") * 17 }
            }
            for proposal in answer.proposals.filter({ $0.state == .waiting }).prefix(2) { height += 82 + lines(proposal.change.line()) * 18 }
            if answer.projects.contains(where: { $0.state == .waiting }) { height += 26 }
            return min(height, 560)
        case .everyday:
            return 10 + 136 + 12 + 36 + 16
        }
    }

    private func resize() {
        guard let geometry else { return }
        if model.isOpen {
            // Room is made first; the panel then grows into it.
            shrink?.cancel()
            shrink = nil
            closing += 1
            let rect = geometry.open(width: openWidth, height: openHeight)
            let frame = NSRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
            if panel.frame != frame { panel.setFrame(frame, display: true, animate: false) }
        } else if panel.frame.height > geometry.resting.height + 1, shrink == nil {
            // The panel is slipping away: the window keeps its size until it has gone, so the
            // movement is not cut off, then takes up only the strip at the notch again.
            closing += 1
            let mine = closing
            shrink = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: UInt64((NotchView.closeSeconds + 0.04) * 1_000_000_000))
                // Opened again, or closed again, since this was set going: that one is in charge now.
                guard let self, mine == self.closing else { return }
                self.shrink = nil
                guard !self.model.isOpen, let resting = self.geometry?.resting else { return }
                self.panel.setFrame(NSRect(x: resting.x, y: resting.y, width: resting.width, height: resting.height), display: true, animate: false)
            }
        }
        // Closed, the panel must not be left holding the keyboard: typing goes back to the app in front.
        if !model.isOpen, panel.isKeyWindow {
            panel.makeFirstResponder(nil)
            panel.orderOut(nil)
            panel.orderFrontRegardless()
        }
    }
}
