import AppKit
import SwiftUI

/// A panel that can take typing without making OMNIS the active app, so the
/// app you were using stays in front behind it.
final class ChatPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

/// Owns the chat window: where it sits, showing and hiding it, and the keys
/// the text field would otherwise swallow. The window stays where you put it
/// and stays open until you close it.
@MainActor
final class ChatWindowController: NSObject, NSWindowDelegate {
    private let model: ChatModel
    private let panel: ChatPanel
    private var keyMonitor: Any?

    private static let defaultSize = NSSize(width: 430, height: 620)
    private static let minimumSize = NSSize(width: 360, height: 440)
    private static let frameKey = "OMNISChatWindowFrame"

    init(model: ChatModel) {
        self.model = model
        panel = ChatPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .resizable],
            backing: .buffered,
            defer: false
        )
        super.init()

        panel.isFloatingPanel = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.animationBehavior = .none
        panel.minSize = Self.minimumSize
        panel.setAccessibilityTitle("OMNIS")
        panel.contentView = NSHostingView(rootView: ChatView(model: model, onClose: { [weak self] in self?.hide() }))
        panel.delegate = self
        panel.setFrame(Self.startingFrame(), display: false)
    }

    var isVisible: Bool { panel.isVisible }

    /// For development: the window number, so a screenshot can target only this window.
    var windowNumber: Int { panel.windowNumber }

    /// The hotkey: bring the window forward if it is hidden or behind, hide it if you are already in it.
    func toggle() {
        if panel.isVisible && panel.isKeyWindow {
            hide()
        } else {
            show()
        }
    }

    func show() {
        model.prepareForOpen()
        // If the screen it was on has gone (a monitor unplugged), bring it back into view.
        if !Self.isReachable(panel.frame) {
            panel.setFrame(Self.centredFrame(size: panel.frame.size), display: false)
        }
        if !panel.isVisible {
            let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            panel.alphaValue = reduceMotion ? 1 : 0
            panel.makeKeyAndOrderFront(nil)
            if !reduceMotion {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
            }
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
        installKeyMonitor()
    }

    /// Hides the window. The conversation is kept.
    func hide() {
        guard panel.isVisible else { return }
        removeKeyMonitor()
        panel.orderOut(nil)
    }

    // MARK: Position

    func windowDidMove(_ notification: Notification) { saveFrame() }
    func windowDidEndLiveResize(_ notification: Notification) { saveFrame() }

    private func saveFrame() {
        UserDefaults.standard.set(NSStringFromRect(panel.frame), forKey: Self.frameKey)
    }

    /// Where you last left it, if that is still on a connected screen; otherwise the centre.
    private static func startingFrame() -> NSRect {
        if let saved = UserDefaults.standard.string(forKey: frameKey) {
            let frame = NSRectFromString(saved)
            if frame.width >= minimumSize.width, frame.height >= minimumSize.height, isReachable(frame) {
                return frame
            }
        }
        return centredFrame(size: defaultSize)
    }

    /// True if enough of the window is on a connected screen to grab and use.
    private static func isReachable(_ frame: NSRect) -> Bool {
        NSScreen.screens.contains {
            let overlap = $0.visibleFrame.intersection(frame)
            return overlap.width >= 120 && overlap.height >= 120
        }
    }

    private static func centredFrame(size: NSSize) -> NSRect {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1280, height: 800)
        return NSRect(
            x: (visible.midX - size.width / 2).rounded(),
            y: (visible.midY - size.height / 2).rounded(),
            width: size.width,
            height: size.height
        )
    }

    // MARK: Keys

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, event.window === self.panel else { return event }
            // Command-V with a picture or files on the clipboard attaches them.
            if event.keyCode == 9, event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               self.model.attachFromPasteboard() {
                return nil
            }
            switch event.keyCode {
            case 53: // escape
                self.hide()
                return nil
            case 125 where !self.model.suggestions.isEmpty: // down arrow
                self.model.moveSelection(by: 1)
                return nil
            case 126 where !self.model.suggestions.isEmpty: // up arrow
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
