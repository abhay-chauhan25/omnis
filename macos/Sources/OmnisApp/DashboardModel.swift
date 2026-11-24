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

    func windowOpened() {
        isVisible = true
        // The calendar read is noted once each time the window opens, not on every refresh.
        logNextAgendaRead = true
        refresh()
        refreshTimer?.invalidate()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func windowClosed() {
        isVisible = false
        refreshTimer?.invalidate()
        refreshTimer = nil
    }

    func refresh() {
        now = Date()
        claudeSessionOpen = claude?.isSessionOpen ?? false
        notesToday = notes.countToday()

        let entries: [RegistryEntry]
        if let config = try? ConfigStore.loadOrCreate(at: OmnisPaths.registryFile), let registry = try? Registry.load(config: config) {
            entries = registry.entries
        } else {
            entries = []
        }
        audit.flush()
        let records = AuditLog.recent(at: OmnisPaths.auditLog)
        activity = DashboardData.activity(from: records)
        history = DashboardData.history(from: records)
        tiles = DashboardData.tiles(from: records, entries: entries)

        // Running Claude Code sessions are looked up off the main thread.
        let ownSession = OmnisPaths.supportDirectory.appendingPathComponent("claude-session", isDirectory: true)
        let projectEntries = entries.filter { $0.kind == .project }
        let recent = DashboardData.tiles(from: records, entries: projectEntries, limit: 5)
        Task { [weak self] in
            let found = await Task.detached(priority: .utility) { SessionScanner.scan(excluding: [ownSession]) }.value
            guard let self else { return }
            self.sessions = found
            // Projects with a session running come first, then the ones opened most.
            let live = projectEntries.filter { entry in found.contains { $0.folder == entry.url.standardizedFileURL.path } }
            var shown = live
            for entry in recent where !shown.contains(entry) { shown.append(entry) }
            self.projects = Array(shown.prefix(6))
        }
        refreshAgenda()
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
        sessions.first { $0.folder == entry.url.standardizedFileURL.path }
    }

    /// Sessions running in folders that are not registered projects.
    var otherSessions: [SessionScanner.Session] {
        sessions.filter { session in !projects.contains { $0.url.standardizedFileURL.path == session.folder } }
    }

    // MARK: Actions

    /// Sends the question to the chat window, where the conversation happens.
    func submit() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !chat.isAnswering else { return }
        ask = ""
        openChat()
        chat.input = text
        chat.send()
    }

    func launch(_ entry: RegistryEntry) {
        chat.launch(entry)
        // Give the record a moment to be written, then show it.
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
            tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.tick() }
            }
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
