import AppKit
import OmnisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var popup: PopupController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var backend: BackendService?
    private var searchContainer: SearXNGContainer?
    private let audit = AuditLog(url: OmnisPaths.auditLog)

    func applicationDidFinishLaunching(_ notification: Notification) {
        // A backend that has just exited must give a write error, not end the app.
        signal(SIGPIPE, SIG_IGN)

        let web = AppEnvironment.webSearch()
        searchContainer = web?.container
        if AppEnvironment.checkWebSearch {
            runWebSearchCheck(web?.search)
            return
        }
        backend = AppEnvironment.backendConfig().map { BackendService(config: $0, webSearch: web?.search) }
        let model = PopupModel(backend: backend, audit: audit)
        popup = PopupController(model: model)

        buildMainMenu()
        buildStatusItem()

        hotKey = HotKey.controlSpace { [weak self] in self?.popup.toggle() }
        if hotKey == nil { reportHotKeyUnavailable() }

        if AppEnvironment.showOnLaunch {
            popup.show()
            if let query = AppEnvironment.initialQuery { model.query = query }
            print("window \(popup.windowNumber)")
            fflush(stdout)
        }
    }

    /// Clicking the Dock icon opens the popup.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        popup.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        backend?.stop()
        // Leave nothing running: stop the search container if it is up.
        searchContainer?.stopNow()
        audit.flush()
    }

    private func runWebSearchCheck(_ search: SearXNGSearch?) {
        Task {
            guard let search else {
                print("web search check: Docker was not found")
                exit(2)
            }
            do {
                let results = try await search.search("OMNIS web search check")
                print("web search check: ok, \(results.count) results, first from \(results.first?.host ?? "none")")
                await search.shutdown()
                exit(0)
            } catch {
                print("web search check: failed, \(error.localizedDescription)")
                await search.shutdown()
                exit(1)
            }
        }
    }

    @objc private func openPopup() {
        popup.show()
    }

    // MARK: Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "OMNIS")
            button.toolTip = "OMNIS"
        }
        let menu = NSMenu()
        let open = NSMenuItem(title: "Open OMNIS", action: #selector(openPopup), keyEquivalent: "")
        open.target = self
        menu.addItem(open)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit OMNIS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem.menu = menu
    }

    private func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        let open = NSMenuItem(title: "Open OMNIS", action: #selector(openPopup), keyEquivalent: "")
        open.target = self
        appMenu.addItem(open)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Quit OMNIS", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Without an Edit menu, Cut/Copy/Paste shortcuts do nothing in the text field.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        let redo = NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(redo)
        editMenu.addItem(.separator())
        editMenu.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        editMenu.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        editMenu.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        editMenu.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = editMenu
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    private func reportHotKeyUnavailable() {
        audit.record(action: "hotkey", outcome: "error", detail: "Control+Space could not be registered")
        let alert = NSAlert()
        alert.messageText = "Control+Space is not available"
        alert.informativeText = "Another app or a macOS shortcut is already using Control+Space. OMNIS is still running: open it from the menu-bar icon or the Dock."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }
}
