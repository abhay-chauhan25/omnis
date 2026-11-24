import AppKit
import OmnisCore
import SwiftUI

/// Everything the dashboard shows. It reads what OMNIS already knows (the
/// calendar, the registry, its own activity record) and refreshes only while
/// the window is open, so a closed dashboard costs nothing.
@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var now = Date()
    @Published private(set) var agenda: [DashboardData.AgendaRow] = []
    @Published private(set) var tomorrowLine: String?
    @Published private(set) var calendarAllowed = EventKitCalendar.isAllowed
    @Published private(set) var tiles: [RegistryEntry] = []
    @Published private(set) var projects: [RegistryEntry] = []
    @Published private(set) var sessions: [SessionScanner.Session] = []
    @Published private(set) var activity: [DashboardData.ActivityLine] = []
    @Published private(set) var history = DashboardData.history(from: [])
    @Published private(set) var notesToday = 0
    @Published private(set) var claudeSessionOpen = false
    @Published private(set) var isVisible = false
    @Published private(set) var focus = FocusTimer()
    @Published private(set) var focusDone = false
    @Published private(set) var captureNotice: String?
    @Published var ask = ""
    @Published var capture = ""

    let chat: ChatModel
    private let calendar: EventKitCalendar
    private let claude: ClaudeService?
    private let audit: AuditLog
    private let notes = NotesStore()
    private let openChat: () -> Void
    private var refreshTimer: Timer?
    private var tickTimer: Timer?
    private var logNextAgendaRead = false

    init(chat: ChatModel, calendar: EventKitCalendar, claude: ClaudeService?, audit: AuditLog, openChat: @escaping () -> Void) {
        self.chat = chat
        self.calendar = calendar
        self.claude = claude
        self.audit = audit
        self.openChat = openChat
    }

    // MARK: Lifecycle

    /// Called whenever the window comes onto, or leaves, the screen: opened,
    /// closed, minimised, covered by other windows, or moved to another
    /// desktop. Nothing is refreshed or drawn while it cannot be seen.
    func setOnScreen(_ onScreen: Bool) {
        guard onScreen != isVisible else { return }
        isVisible = onScreen
        refreshTimer?.invalidate()
        refreshTimer = nil
        guard onScreen else { return }
        // The calendar read is noted once each time the window appears, not on every refresh.
        logNextAgendaRead = true
        chat.reloadRegistry()
        refresh()
        let timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        timer.tolerance = 5
        refreshTimer = timer
    }

    func refresh() {
        now = Date()
        claudeSessionOpen = claude?.isSessionOpen ?? false
        notesToday = notes.countToday()
        refreshAgenda()

        let entries = chat.registryEntries
        let audit = self.audit
        let ownSession = OmnisPaths.supportDirectory.appendingPathComponent("claude-session", isDirectory: true)
        // Reading the activity record and looking for running sessions both
        // happen off the main thread, so the window never stutters.
        Task { [weak self] in
            let loaded = await Task.detached(priority: .utility) { () -> Loaded in
                audit.flush()
                let records = AuditLog.recent(at: OmnisPaths.auditLog)
                let projectEntries = entries.filter { $0.kind == .project }
                return Loaded(
                    activity: DashboardData.activity(from: records),
                    history: DashboardData.history(from: records),
                    tiles: DashboardData.tiles(from: records, entries: entries),
                    recentProjects: DashboardData.tiles(from: records, entries: projectEntries, limit: 5),
                    projectEntries: projectEntries,
                    sessions: SessionScanner.scan(excluding: [ownSession])
                )
            }.value
            guard let self else { return }
            self.activity = loaded.activity
            self.history = loaded.history
            self.tiles = loaded.tiles
            self.sessions = loaded.sessions
            // Projects with a session running come first, then the ones opened most.
            var shown = loaded.projectEntries.filter { entry in
                loaded.sessions.contains { $0.folder == entry.url.resolvingSymlinksInPath().path }
            }
            for entry in loaded.recentProjects where !shown.contains(entry) { shown.append(entry) }
            self.projects = Array(shown.prefix(6))
        }
    }

    private struct Loaded: Sendable {
        let activity: [DashboardData.ActivityLine]
        let history: DashboardData.History
        let tiles: [RegistryEntry]
        let recentProjects: [RegistryEntry]
        let projectEntries: [RegistryEntry]
        let sessions: [SessionScanner.Session]
    }

    /// Reads today and tomorrow from the calendar, but only once the user has
    /// allowed calendar access: opening the dashboard never shows a prompt.
    private func refreshAgenda() {
        calendarAllowed = EventKitCalendar.isAllowed
        guard calendarAllowed else { return }
        loadAgenda()
    }

    /// The "Allow" button on the Today panel. This is what makes macOS ask.
    func allowCalendar() {
        logNextAgendaRead = true
        loadAgenda()
    }

    private func loadAgenda() {
        let reader = calendar
        Task { [weak self] in
            let current = Calendar.current
            let start = current.startOfDay(for: Date())
            guard let end = current.date(byAdding: .day, value: 2, to: start),
                  let events = try? await reader.events(from: start, to: end) else {
                self?.calendarAllowed = EventKitCalendar.isAllowed
                return
            }
            guard let self else { return }
            self.calendarAllowed = true
            let moment = Date()
            self.agenda = DashboardData.agenda(from: events, now: moment)
            let tomorrow = current.date(byAdding: .day, value: 1, to: start) ?? start
            let first = events.filter { current.isDate($0.start, inSameDayAs: tomorrow) && !$0.allDay }.min { $0.start < $1.start }
            if let first, let row = DashboardData.agenda(from: [first], now: tomorrow).first {
                self.tomorrowLine = "Tomorrow starts with \(row.title) at \(row.time)."
            } else {
                self.tomorrowLine = "Nothing timed on tomorrow yet."
            }
            if self.logNextAgendaRead {
                self.logNextAgendaRead = false
                // Counts only, as for any calendar read.
                self.audit.record(action: "calendar_read", outcome: "ok", detail: "\(events.count) events, for the dashboard")
            }
        }
    }

    // MARK: Text shown

    var greeting: String { DashboardData.greeting(now: now) }

    var summary: String {
        if !calendarAllowed { return "Allow calendar access to see your day here." }
        if let next = agenda.first(where: \.isNext) { return "\(next.title) starts at \(next.time)." }
        return agenda.isEmpty ? "Nothing on your calendar for the rest of today." : "Nothing more starts today."
    }

    var nextBadge: String? { DashboardData.untilNext(agenda, now: now).map { "NEXT \($0.uppercased())" } }

    var clock: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: now)
    }

    var dateLine: String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEE d MMM yyyy"
        return formatter.string(from: now)
    }

    func session(for entry: RegistryEntry) -> SessionScanner.Session? {
        sessions.first { $0.folder == entry.url.resolvingSymlinksInPath().path }
    }

    /// Sessions running in folders that are not registered projects.
    var otherSessions: [SessionScanner.Session] {
        sessions.filter { session in !projects.contains { $0.url.resolvingSymlinksInPath().path == session.folder } }
    }

    // MARK: Actions

    /// Sends the question to the chat window, where the conversation happens.
    func submit() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isAnswering else { return }
        ask = ""
        // A clear request to open something is launched at once, with no chat window needed.
        if LaunchSuggestion.suggest(for: text, registry: Registry(entries: chat.registryEntries, editor: RegistryConfig.standard.editor)).preselect
            || SlashCommand.parse(text) != nil {
            chat.askFromDashboard(text)
            refreshSoon()
            return
        }
        openChat()
        chat.askFromDashboard(text)
    }

    func launch(_ entry: RegistryEntry) {
        chat.launch(entry, clearInput: false)
        refreshSoon()
    }

    /// Gives a record a moment to be written, then shows it.
    private func refreshSoon() {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 600_000_000)
            self?.refresh()
        }
    }

    func saveCapture() {
        let text = capture
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if notes.add(text) {
            capture = ""
            notesToday = notes.countToday()
            // That a note was kept, never what it says.
            audit.record(action: "note", outcome: "ok")
            captureNotice = nil
        } else {
            captureNotice = "That could not be saved."
        }
    }

    func openNotes() {
        if FileManager.default.fileExists(atPath: OmnisPaths.notesFile.path) { NSWorkspace.shared.open(OmnisPaths.notesFile) }
    }

    func toggleFocus() {
        focusDone = false
        if focus.isRunning {
            focus.stop()
            tickTimer?.invalidate()
            tickTimer = nil
        } else {
            focus.start()
            let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
            timer.tolerance = 0.3
            tickTimer = timer
        }
    }

    private func tick() {
        now = Date()
        guard focus.isFinished(now: now) else { return }
        focus.stop()
        tickTimer?.invalidate()
        tickTimer = nil
        focusDone = true
        NSSound.beep()
        AccessibilityNotification.Announcement("Focus time finished").post()
    }

    var focusLabel: String { focus.label(now: now) }
}
