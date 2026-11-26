import AppKit
import OmnisCore
import OmnisHelperLink
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var chat: ChatWindowController!
    private var hotKey: HotKey?
    private var statusItem: NSStatusItem!
    private var backend: BackendService?
    private var claude: ClaudeService?
    private var dashboard: DashboardWindowController!
    private var projectMode: ProjectModeModel!
    private var voice: VoiceModel!
    private var notchModel: NotchModel!
    private var notch: NotchWindowController?
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
        if AppEnvironment.checkMessagesReader {
            guard let reader = AppEnvironment.messagesReader() else {
                print("messages reader check: this build has no reader (it needs the stable signing identity)")
                exit(2)
            }
            do {
                let reply = try reader.ask(ReaderRequest(op: "chats", limit: 40))
                print("messages reader check: ok, it is the real reader and it can see \(reply.chats?.count ?? 0) recent conversations")
                exit(0)
            } catch {
                print("messages reader check: \(error.localizedDescription)")
                exit(1)
            }
        }
        // The calendar is read by the app through EventKit. macOS asks for
        // permission the first time a question needs it.
        let calendar = EventKitCalendar()
        // One set of calendar tools serves both the model on this Mac and
        // Claude, so both go through the same checks.
        let tools = CalendarTools(reader: calendar)
        backend = AppEnvironment.backendConfig().map {
            BackendService(config: $0, webSearch: web?.search, tools: tools)
        }
        // Claude answers by default, through Claude Code on the user's own plan.
        // Setting up a project needs git and the GitHub tool. Without them it is simply not offered.
        let projectSetup: ProjectSetup? = {
            guard let git = Commands.find("git"), let gh = Commands.find("gh") else { return nil }
            return ProjectSetup(git: git, gh: gh)
        }()
        let planner: ClaudeService.ProjectPlanner? = projectSetup.map { setup in
            { arguments in
                // New projects go in the first projects folder named in the registry.
                let config = try ConfigStore.loadOrCreate(at: OmnisPaths.registryFile)
                guard let first = config.projectRoots.first else { throw ProjectError.noProjectsFolder("(none set)") }
                let root = URL(fileURLWithPath: NSString(string: first).expandingTildeInPath, isDirectory: true)
                return try ProjectPlan.make(arguments: arguments, root: root, owner: await setup.owner())
            }
        }
        // Other services Claude can use through OMNIS. Each is offered only if it can work on this Mac.
        let reminderStore = EventKitReminders()
        var services: [any AssistantTools] = [RemindersTools(store: reminderStore)]
        // Photos are read through Apple's own interface; macOS asks the first time one is wanted.
        services.append(PhotosTools(library: PhotoKitLibrary()))
        // A message is only ever prepared; the user's click on the preview sends it.
        services.append(MessagesTools(contacts: SystemContacts(), sender: MessagesAppSender()))
        // Email is read through the Mail app, and only read; macOS asks the first time.
        services.append(MailTools())
        if let gh = Commands.find("gh") { services.append(GitHubTools(gh: gh)) }
        // Spotify plays here; finding a song by name uses its catalogue, once the user has connected it.
        let spotify = FileManager.default.fileExists(atPath: "/Applications/Spotify.app") ? SpotifyAccount() : nil
        if let spotify { services.append(SpotifyTools(catalogue: spotify)) }
        // Opening a saved app or project when asked in looser words than the instant launcher takes.
        services.append(AppsTools(registry: {
            (try? ConfigStore.loadOrCreate(at: OmnisPaths.registryFile)).flatMap { try? Registry.load(config: $0) }
        }, performer: SystemLaunchPerformer()))
        claude = AppEnvironment.claudeConfig().map { ClaudeService(config: $0, tools: tools, projects: planner, services: services) }
        // Changing the calendar goes through the chat model, on the user's click.
        let model = ChatModel(backend: backend, audit: audit, calendarWriter: calendar, claude: claude,
                              projectSetup: projectSetup, services: services, spotify: spotify)
        chat = ChatWindowController(model: model)
        // The dashboard is the main window. A question typed there is answered in the chat window.
        let dashboardModel = DashboardModel(chat: model, calendar: calendar, claude: claude, audit: audit,
                                            openChat: { [weak self] in self?.chat.show() })
        projectMode = ProjectModeModel(chat: model, claudeConfig: AppEnvironment.claudeConfig(), audit: audit)
        if let lines = AppEnvironment.voiceRehearsal {
            // No windows, no hotkey, no microphone: only the conversation itself.
            voice = VoiceModel(chat: model, audit: audit, autoStart: false)
            let started = Date()
            voice.rehearse(lines, report: { line in
                print(String(format: "[%5.1fs] %@", Date().timeIntervalSince(started), line))
                fflush(stdout)
            }, finished: { exit(0) })
            return
        }
        // Something that needs the user's eyes during a spoken conversation is shown in
        // the notch panel when there is one, and in the chat window otherwise.
        voice = VoiceModel(chat: model, audit: audit, trace: AppEnvironment.voiceTrace, showChat: { [weak self] in
            guard let self else { return }
            if let notch = self.notch, notch.isAvailable, !self.dashboard.isVisible { self.notchModel.reveal() } else { self.chat.show() }
        })
        dashboard = DashboardWindowController(model: dashboardModel, chat: model, project: projectMode, voice: voice)
        // The panel at the notch: voice away from the dashboard, and a few everyday things on hover.
        notchModel = NotchModel(dashboard: dashboardModel, chat: model, voice: voice,
                                music: services.first { $0.service == "spotify" }, reminders: reminderStore, audit: audit)
        if let folder = AppEnvironment.renderNotch {
            renderNotch(to: folder)
            return
        }
        notch = NotchWindowController(model: notchModel)
        // "Continue VoyagerAI in project mode", from either window, lands here.
        model.openProjectMode = { [weak self] entry, resume in
            self?.dashboard.show()
            self?.projectMode.open(entry, resume: resume)
        }

        buildMainMenu()
        buildStatusItem()

        hotKey = HotKey.controlSpace { [weak self] in self?.chat.toggle() }
        if hotKey == nil { reportHotKeyUnavailable() }

        if AppEnvironment.showOnLaunch {
            chat.show()
            if let query = AppEnvironment.initialQuery { model.input = query }
            print("window \(chat.windowNumber)")
            fflush(stdout)
        } else {
            // Opening OMNIS shows its main window.
            dashboard.show()
        }
    }

    /// Clicking the Dock icon opens the chat window.
    /// Clicking the Dock icon opens the dashboard. Control+Space is still the quick chat.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        dashboard.show()
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Quitting ends any Claude Code sessions in project mode, so it asks first.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let projectMode, projectMode.runningCount > 0 else { return .terminateNow }
        let alert = NSAlert()
        let count = projectMode.runningCount
        alert.messageText = count == 1 ? "A Claude Code session is still running" : "\(count) Claude Code sessions are still running"
        alert.informativeText = "Quitting OMNIS ends them. Their work so far is kept, and you can pick a session up again with \u{201C}Resume the last one\u{201D}."
        alert.addButton(withTitle: "Quit")
        alert.addButton(withTitle: "Cancel")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        projectMode?.closeAll()
        // The microphone is let go of before anything else.
        if voice?.isOn == true { voice.stopForQuit() }
        backend?.stop()
        // Waits until Claude Code has gone, so nothing is left running.
        claude?.shutdown()
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

    /// Draws the notch panel's two views to pictures, over a plain backdrop, and exits.
    private func renderNotch(to folder: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        Task { @MainActor in
            for (name, voiceView, height) in [("everyday", false, 32.0 + 10 + 136 + 12 + 36 + 16), ("voice", true, 32.0 + 142)] {
                notchModel.showForPicture(voice: voiceView)
                // Time for the calendar, the music and the tiles to arrive.
                try? await Task.sleep(nanoseconds: 400_000_000)
                let picture = ZStack(alignment: .top) {
                    LinearGradient(colors: [Color(red: 0.36, green: 0.47, blue: 0.62), Color(red: 0.62, green: 0.56, blue: 0.48)],
                                   startPoint: .top, endPoint: .bottom)
                    NotchView(model: notchModel, notchHeight: 32, notchWidth: 185).frame(width: voiceView ? 540 : 720, height: height)
                    // Where the real notch would be.
                    UnevenRoundedRectangle(bottomLeadingRadius: 9, bottomTrailingRadius: 9).fill(.black).frame(width: 185, height: 32)
                }
                .frame(width: 900, height: height + 70)
                let renderer = ImageRenderer(content: picture)
                renderer.scale = 2
                if let image = renderer.nsImage, let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff),
                   let png = bitmap.representation(using: .png, properties: [:]) {
                    try? png.write(to: folder.appendingPathComponent("\(name).png"))
                    print("drew \(name)")
                }
            }
            exit(0)
        }
    }

    @objc private func openPopup() {
        chat.show()
    }

    @objc private func openDashboard() {
        dashboard.show()
    }

    // MARK: Menus

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            // The Halo mark, drawn in black so macOS tints it for light and dark menu bars.
            if let mark = Bundle.main.image(forResource: "MenuIcon") {
                mark.isTemplate = true
                mark.size = NSSize(width: 18, height: 18)
                mark.accessibilityDescription = "OMNIS"
                button.image = mark
            } else {
                button.image = NSImage(systemSymbolName: "sparkle", accessibilityDescription: "OMNIS")
            }
            button.toolTip = "OMNIS"
        }
        let menu = NSMenu()
        let board = NSMenuItem(title: "Open Dashboard", action: #selector(openDashboard), keyEquivalent: "")
        board.target = self
        menu.addItem(board)
        let open = NSMenuItem(title: "Open Chat", action: #selector(openPopup), keyEquivalent: "")
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
