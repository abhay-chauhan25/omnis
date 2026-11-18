import AppKit
import OmnisCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chat: ChatWindowController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var backend: BackendService?
    private var searchContainer: SearXNGContainer?
    private let audit = AuditLog(url: OmnisPaths.auditLog)
    private let ledger = UsageLedger(url: OmnisPaths.usageLedger, mirror: .standard)

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
        let model = ChatModel(backend: backend, audit: audit, ledger: ledger)
        chat = ChatWindowController(model: model)

        buildMainMenu()
        buildStatusItem()

        hotKey = HotKey.controlSpace { [weak self] in self?.chat.toggle() }
        if hotKey == nil { reportHotKeyUnavailable() }

        if AppEnvironment.showOnLaunch {
            chat.show()
            if let query = AppEnvironment.initialQuery { model.input = query }
            print("window \(chat.windowNumber)")
            fflush(stdout)
        }
    }

    /// Clicking the Dock icon opens the chat window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        chat.show()
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

    /// Asks for the Claude API key and keeps it in the Keychain. The field
    /// hides what is typed, and the key is never shown again or written to a file.
    @objc private func setClaudeKey() {
        let hasKey = KeychainStore.claudeKey.read() != nil
        let alert = NSAlert()
        alert.messageText = "Claude API key"
        alert.informativeText = hasKey
            ? "A key is saved. Paste a new one to replace it, or remove it to keep every answer on this Mac."
            : "Paste your Anthropic API key to let OMNIS send public questions to Claude. It is stored in the macOS Keychain. Without a key, every answer comes from the model on this Mac."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "sk-ant-..."
        alert.accessoryView = field
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        if hasKey { alert.addButton(withTitle: "Remove Key") }
        alert.window.initialFirstResponder = field
        NSApp.activate(ignoringOtherApps: true)

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            guard !field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            let saved = KeychainStore.claudeKey.save(field.stringValue)
            audit.record(action: "claude_key", outcome: saved ? "saved" : "error")
            if !saved {
                let failure = NSAlert()
                failure.messageText = "The key could not be saved"
                failure.informativeText = "The macOS Keychain refused it. Any key saved earlier is unchanged."
                failure.runModal()
                return
            }
        case .alertThirdButtonReturn:
            KeychainStore.claudeKey.delete()
            audit.record(action: "claude_key", outcome: "removed")
        default:
            return
        }
        // The backend reads the key when it starts, so restart it.
        backend?.stop()
    }

    @objc private func openPopup() {
        chat.show()
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
        let key = NSMenuItem(title: "Claude API Key\u{2026}", action: #selector(setClaudeKey), keyEquivalent: "")
        key.target = self
        menu.addItem(key)
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
