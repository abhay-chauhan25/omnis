import AppKit
import OmnisCore
import SwiftTerm
import SwiftUI

/// Project mode: real Claude Code terminals for one project, with OMNIS
/// beside them as a read-only advisor.
@MainActor
final class ProjectModeModel: ObservableObject {
    /// One terminal running Claude Code.
    struct Tab: Identifiable {
        let id = UUID()
        var title: String
        let project: RegistryEntry
        let view: LocalProcessTerminalView
        let watcher: TerminalWatcher
        var ended = false
    }

    struct AdvisorMessage: Identifiable, Equatable {
        let id = UUID()
        let fromUser: Bool
        var text: String
        var failed = false
    }

    @Published var isActive = false {
        didSet { if isActive != oldValue { activeChanged() } }
    }
    @Published private(set) var projects: [RegistryEntry] = []
    @Published private(set) var selected: RegistryEntry?
    @Published private(set) var tabs: [Tab] = []
    @Published var activeTab: UUID?
    @Published private(set) var activity: SessionActivity?
    @Published private(set) var changedFiles: [String] = []
    @Published private(set) var advisor: [AdvisorMessage] = []
    @Published private(set) var advisorBusy = false
    @Published var question = ""
    @Published var brief = ""
    @Published var showBrief = false
    @Published private(set) var notice: String?
    /// Whether the plain shell under the Claude terminal is showing. Remembered between runs.
    @Published var showShell = UserDefaults.standard.bool(forKey: "OMNISProjectShell") {
        didSet { UserDefaults.standard.set(showShell, forKey: "OMNISProjectShell") }
    }
    /// One ordinary shell per project, for the user's own commands. Kept
    /// while OMNIS runs, so its history survives hiding and showing it.
    private var shells: [String: (view: LocalProcessTerminalView, watcher: TerminalWatcher)] = [:]
    @Published private var shellGeneration = 0

    private let chat: ChatModel
    private let claudeConfig: ClaudeConfig?
    private let git: URL?
    private let audit: AuditLog
    private var advisorService: ClaudeService?
    private var advisorTask: Task<Void, Never>?
    private var refreshTimer: Timer?
    private var onScreen = false
    private static let projectKey = "OMNISProjectModeProject"

    init(chat: ChatModel, claudeConfig: ClaudeConfig?, audit: AuditLog) {
        self.chat = chat
        self.claudeConfig = claudeConfig
        self.audit = audit
        self.git = Commands.find("git")
    }

    var available: Bool { claudeConfig != nil }
    var visibleTabs: [Tab] { tabs.filter { $0.project == selected } }
    var currentTab: Tab? { visibleTabs.first { $0.id == activeTab } ?? visibleTabs.first }
    var runningCount: Int { tabs.filter { !$0.ended }.count }

    // MARK: Lifecycle

    func setOnScreen(_ value: Bool) {
        onScreen = value
        activeChanged()
    }

    private func activeChanged() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard isActive, onScreen else { return }
        reloadProjects()
        refresh()
        // What the session is doing is read every few seconds, and only while this view can be seen.
        let timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 1
        refreshTimer = timer
    }

    private func reloadProjects() {
        chat.reloadRegistry()
        projects = chat.registryEntries.filter { $0.kind == .project }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        if selected == nil || !projects.contains(where: { $0 == selected }) {
            let remembered = UserDefaults.standard.string(forKey: Self.projectKey)
            select(projects.first { $0.name == remembered } ?? projects.first)
        }
    }

    /// Switches to project mode for one project. With `resume`, and if no
    /// session is open for it yet, its last session is picked up.
    func open(_ project: RegistryEntry, resume: Bool) {
        isActive = true
        reloadProjects()
        guard let match = projects.first(where: { $0.id == project.id }) else { return }
        select(match)
        if resume, visibleTabs.isEmpty { openTerminal(resume: true) }
    }

    func select(_ project: RegistryEntry?) {
        guard project != selected else { return }
        selected = project
        if let project { UserDefaults.standard.set(project.name, forKey: Self.projectKey) }
        activeTab = visibleTabs.first?.id
        // A different project means a different advisor: the old one saw the old project's files.
        advisorTask?.cancel()
        advisorService?.endSession()
        advisorService = nil
        advisor = []
        advisorBusy = false
        activity = nil
        changedFiles = []
        refresh()
    }

    func refresh() {
        guard let project = selected else { return }
        let folder = project.url
        let git = self.git
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> (SessionActivity?, [String]) in
                let activity = SessionTranscripts.load(project: folder)
                let files = git == nil ? [] : await ProjectFiles.changed(in: folder, git: git!)
                return (activity, files)
            }.value
            guard let self, self.selected == project else { return }
            self.activity = loaded.0
            self.changedFiles = loaded.1
        }
    }

    // MARK: Terminals

    /// Opens a terminal running the user's own Claude Code in the project's folder.
    func openTerminal(resume: Bool = false, brief: String? = nil) {
        guard let project = selected, let claudeConfig else { return }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 500))
        view.font = NSFont.monospacedSystemFont(ofSize: 12.5, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.035, green: 0.043, blue: 0.058, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0.91, green: 0.93, blue: 0.95, alpha: 1)
        view.caretColor = NSColor(red: 0.949, green: 0.757, blue: 0.306, alpha: 1)
        let watcher = TerminalWatcher()
        view.processDelegate = watcher
        let number = tabs.filter { $0.project == project }.count + 1
        let tab = Tab(title: resume ? "Resumed" : "Session \(number)", project: project, view: view, watcher: watcher)
        // Only the id is kept by these, so a closed tab's terminal is freed.
        let tabID = tab.id
        watcher.ended = { [weak self] in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == tabID }) else { return }
            self.tabs[index].ended = true
        }
        watcher.titled = { [weak self] title in
            guard let self, let index = self.tabs.firstIndex(where: { $0.id == tabID }), !title.isEmpty else { return }
            self.tabs[index].title = String(title.prefix(28))
        }
        tabs.append(tab)
        activeTab = tab.id

        let launch = ProjectSession.launch(
            claude: claudeConfig.executable,
            arguments: ProjectSession.arguments(name: project.name, resume: resume, brief: brief)
        )
        view.startProcess(executable: launch.executable, args: launch.arguments,
                          environment: Self.environment(),
                          currentDirectory: project.url.path)
        // The project's name is the user's own, recorded like any launch.
        audit.record(action: "project_session", target: project.name, outcome: "ok", detail: resume ? "resumed" : (brief == nil ? "new" : "from a brief"))
    }

    func startFromBrief() {
        let text = brief.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        showBrief = false
        brief = ""
        openTerminal(brief: text)
    }

    func close(_ id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        if !tabs[index].ended { tabs[index].view.terminate() }
        tabs.remove(at: index)
        if activeTab == id { activeTab = visibleTabs.last?.id }
    }

    /// The user's own shell for the current project: an ordinary terminal
    /// in the project's folder. It is theirs alone; no model reads or types in it.
    func shell() -> LocalProcessTerminalView? {
        guard let project = selected else { return nil }
        if let existing = shells[project.id] { return existing.view }
        let view = LocalProcessTerminalView(frame: NSRect(x: 0, y: 0, width: 800, height: 180))
        view.font = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
        view.nativeBackgroundColor = NSColor(red: 0.027, green: 0.033, blue: 0.045, alpha: 1)
        view.nativeForegroundColor = NSColor(red: 0.91, green: 0.93, blue: 0.95, alpha: 1)
        view.caretColor = NSColor(red: 0.949, green: 0.757, blue: 0.306, alpha: 1)
        let watcher = TerminalWatcher()
        view.processDelegate = watcher
        let id = project.id
        // Typing "exit" closes the shell; the next time it is shown, a fresh one starts.
        watcher.ended = { [weak self] in
            self?.shells[id] = nil
            self?.shellGeneration += 1
        }
        shells[id] = (view, watcher)
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.hasPrefix("/") ? $0 : nil } ?? "/bin/zsh"
        view.startProcess(executable: shell, args: ["-l", "-i"], environment: Self.environment(), currentDirectory: project.url.path)
        return view
    }

    /// Changes whenever a shell ends, so the view asks for a new one.
    var shellKey: String { "\(selected?.id ?? "")-\(shellGeneration)" }

    /// Ends every session. Called when OMNIS quits.
    func closeAll() {
        for shell in shells.values { shell.view.terminate() }
        shells = [:]
        for tab in tabs where !tab.ended { tab.view.terminate() }
        tabs = []
        advisorService?.shutdown()
    }

    /// Puts text into the current terminal's input, as a paste. It is not
    /// sent: the user reads it and presses Return themselves.
    func placeInTerminal(_ text: String) {
        guard let tab = currentTab, !tab.ended else {
            show("Open a terminal session first.")
            return
        }
        // Pasted through the terminal's own paste, with control characters
        // removed first: nothing in the text can end the paste or press a key.
        let safe = ProjectSession.pasteable(text)
        guard !safe.isEmpty else { return }
        tab.view.pasteText(safe)
        tab.view.window?.makeFirstResponder(tab.view)
    }

    /// What a session's terminal starts with: the basics, plus what lets
    /// pushes over SSH and temporary files work as in the user's own terminal.
    static func environment() -> [String] {
        var values = Terminal.getEnvironmentVariables(termName: "xterm-256color")
        let current = ProcessInfo.processInfo.environment
        for key in ["SSH_AUTH_SOCK", "TMPDIR", "SHELL"] {
            if let value = current[key] { values.append("\(key)=\(value)") }
        }
        return values
    }

    /// The prompt in an advisor answer: its first code block if it has one, otherwise all of it.
    static func prompt(in answer: String) -> String {
        let parts = answer.components(separatedBy: "```")
        guard parts.count >= 3 else { return answer.trimmingCharacters(in: .whitespacesAndNewlines) }
        var block = parts[1]
        // Drop a language name on the opening line, as in ```text
        if let newline = block.firstIndex(of: "\n"), !block[..<newline].contains(" "), block[..<newline].count < 16 {
            block = String(block[block.index(after: newline)...])
        }
        return block.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func show(_ text: String) {
        notice = text
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: Advisor

    func askAdvisor() {
        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !advisorBusy, let project = selected, let claudeConfig else { return }
        question = ""
        if advisorService == nil {
            var config = claudeConfig
            config.profile = .advisor(folder: project.url, project: project.name)
            config.workingDirectory = project.url
            advisorService = ClaudeService(config: config, tools: CalendarTools(reader: nil))
        }
        guard let service = advisorService else { return }
        let history = advisor.filter { !$0.failed && !$0.text.isEmpty }.suffix(12).map {
            ChatTurn(role: $0.fromUser ? .user : .assistant, content: $0.text)
        }
        advisor.append(AdvisorMessage(fromUser: true, text: text))
        let answer = AdvisorMessage(fromUser: false, text: "")
        advisor.append(answer)
        advisorBusy = true
        // The advisor is told what the terminal session has been doing, so it can answer questions about it.
        let context = SessionTranscripts.brief(activity, changedFiles: changedFiles)
        let message = "[From OMNIS: what the terminal session has been doing]\n\(context)\n\n[The user's question]\n\(text)"
        let request = ClaudeRequest(text: message, history: Array(history), model: .sonnet, effort: "medium", web: false)
        let answerID = answer.id
        advisorTask = Task { [weak self] in
            do {
                for try await event in service.ask(request) {
                    guard !Task.isCancelled else { return }
                    if case .chunk(let piece) = event { self?.updateAdvisor(answerID) { $0.text += piece } }
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.updateAdvisor(answerID) { $0.text = error.localizedDescription; $0.failed = true }
            }
            self?.advisorBusy = false
        }
    }

    private func updateAdvisor(_ id: UUID, _ change: (inout AdvisorMessage) -> Void) {
        guard let index = advisor.firstIndex(where: { $0.id == id }) else { return }
        change(&advisor[index])
    }
}

/// Tells the model when a terminal's program ends or names itself.
@MainActor
final class TerminalWatcher: NSObject, LocalProcessTerminalViewDelegate {
    var ended: (() -> Void)?
    var titled: ((String) -> Void)?

    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: LocalProcessTerminalView, title: String) { titled?(title) }
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func processTerminated(source: TerminalView, exitCode: Int32?) { ended?() }
}

/// Shows a terminal that already exists. The terminal itself is kept by the
/// model, so switching tabs or leaving project mode does not end its session.
struct TerminalHost: NSViewRepresentable {
    let view: LocalProcessTerminalView

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        attach(to: container)
        return container
    }

    func updateNSView(_ container: NSView, context: Context) {
        if view.superview !== container { attach(to: container) }
    }

    private func attach(to container: NSView) {
        container.subviews.forEach { $0.removeFromSuperview() }
        view.removeFromSuperview()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }
}
