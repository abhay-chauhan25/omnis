import AppKit
import SwiftUI

/// A panel that can take typing without making OMNIS the active app, so the
/// app you were using stays in front behind the bar.
final class PopupPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the popup window: where it appears, how it opens and closes, and the
/// keys that the text field would otherwise swallow.
@MainActor
final class PopupController: NSObject, NSWindowDelegate {
    private let model: PopupModel
    private let panel: PopupPanel
    private var keyMonitor: Any?
    private var closing = false

    /// The window is a fixed transparent canvas; the visible bar grows inside it.
    private static let canvas = NSSize(width: PopupView.barWidth + PopupView.margin * 2, height: 560)
    /// How far down the screen the top of the bar sits.
    private static let topFraction: CGFloat = 0.2

    init(model: PopupModel) {
        self.model = model
        panel = PopupPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.setAccessibilityTitle("OMNIS")
        panel.contentView = NSHostingView(rootView: PopupView(model: model))
        panel.delegate = self

        model.onDismiss = { [weak self] in self?.hide() }
        model.onLateFailure = { [weak self] message in
            guard let self else { return }
            // If the popup is already open again, keep what is being typed.
            if !self.panel.isVisible { self.show() }
            self.model.showFailure(message)
        }
    }

    var isVisible: Bool { panel.isVisible }

    /// For development: the window number, so a screenshot can target only this window.
    var windowNumber: Int { panel.windowNumber }

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        model.prepareForOpen()
        position()

        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        panel.alphaValue = reduceMotion ? 1 : 0
        panel.makeKeyAndOrderFront(nil)
        model.visible = true
        if !reduceMotion {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.14
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.animator().alphaValue = 1
            }
        }
        installKeyMonitor()
    }

    func hide() {
        guard panel.isVisible, !closing else { return }
        closing = true
        defer { closing = false }
        removeKeyMonitor()
        model.visible = false
        panel.orderOut(nil)
        model.reset()
    }

    /// Clicking anywhere else closes the popup.
    func windowDidResignKey(_ notification: Notification) {
        hide()
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(
            x: (frame.midX - Self.canvas.width / 2).rounded(),
            y: (frame.maxY - frame.height * Self.topFraction - Self.canvas.height).rounded()
        )
        panel.setFrame(NSRect(origin: origin, size: Self.canvas), display: true)
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            switch event.keyCode {
            case 53: // escape
                self.hide()
                return nil
            case 125: // down arrow
                self.model.moveSelection(by: 1)
                return nil
            case 126: // up arrow
                self.model.moveSelection(by: -1)
                return nil
            default:
                return event
            }
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}
