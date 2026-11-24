import Combine
import EventKit
import Foundation
import OmnisCore

/// What the notch panel shows. It holds nothing of its own beyond what is
/// playing and today's reminders: the rest comes from the dashboard, the
/// chat and voice, so the panel can never disagree with them.
@MainActor
final class NotchModel: ObservableObject {
    enum Showing: Equatable { case nothing, everyday, voice }

    @Published private(set) var showing: Showing = .nothing
    @Published private(set) var track: (title: String, playing: Bool)?
    @Published private(set) var musicNote: String?
    @Published private(set) var reminders: [String] = []
    @Published var ask = ""
    /// True while the pointer is over the panel.
    private(set) var hovering = false
    /// True while the ask box is being typed in, so the panel does not close under the user.
    var typing = false

    let dashboard: DashboardModel
    let chat: ChatModel
    let voice: VoiceModel
    private let music: (any AssistantTools)?
    private let reminderStore: (any ReminderStoring)?
    private let audit: AuditLog
    private var watching: Set<AnyCancellable> = []
    private var openTask: Task<Void, Never>?
    private var closeTask: Task<Void, Never>?
    private var lastRefresh = Date.distantPast

    init(dashboard: DashboardModel, chat: ChatModel, voice: VoiceModel, music: (any AssistantTools)?,
         reminders: (any ReminderStoring)?, audit: AuditLog) {
        self.dashboard = dashboard
        self.chat = chat
        self.voice = voice
        self.music = music
        self.reminderStore = reminders
        self.audit = audit
        // A spoken conversation shows itself here whenever the dashboard is not there to show it.
        voice.$state.combineLatest(dashboard.$isVisible).sink { [weak self] _, _ in
            Task { @MainActor in self?.voiceChanged() }
        }.store(in: &watching)
        // The panel redraws when what it borrows changes.
        for publisher in [dashboard.objectWillChange, chat.objectWillChange, voice.objectWillChange] {
            publisher.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &watching)
        }
    }

    var isOpen: Bool { showing != .nothing }
    var nextEvent: String? { NotchData.nextEvent(in: dashboard.agenda, now: dashboard.now) }

    /// The preview or question from the latest answer that is waiting on the user, if any.
    var waitingAnswer: ChatMessage? {
        guard let last = chat.conversation.messages.last, last.role == .assistant else { return nil }
        let waits = last.searchAsk?.state == .waiting || last.actions.contains { $0.state == .waiting }
            || last.proposals.contains { $0.state == .waiting } || last.projects.contains { $0.state == .waiting }
        return waits ? last : nil
    }

    // MARK: Opening and closing

    func pointerEntered() {
        hovering = true
        closeTask?.cancel()
        guard showing == .nothing else { return }
        // A short wait, so brushing past the notch does not open it.
        openTask?.cancel()
        openTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let self, self.hovering, self.showing == .nothing else { return }
            self.showing = .everyday
            self.refresh()
        }
    }

    func pointerLeft() {
        hovering = false
        openTask?.cancel()
        scheduleClose(after: 0.5)
    }

    /// Esc, or a click on something that leads elsewhere.
    func close() {
        typing = false
        ask = ""
        if voice.inConversation && !dashboard.isVisible { showing = .voice } else { showing = .nothing }
    }

    /// Shows the panel because something in it needs the user's eyes.
    func reveal() {
        closeTask?.cancel()
        if showing == .nothing { showing = voice.inConversation ? .voice : .everyday }
    }

    private func scheduleClose(after seconds: Double) {
        closeTask?.cancel()
        closeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self, !self.hovering, !self.typing else { return }
            // A conversation keeps the panel open; so does something waiting to be confirmed.
            if self.voice.inConversation && !self.dashboard.isVisible {
                self.showing = .voice
            } else if self.waitingAnswer == nil || self.showing == .everyday {
                self.showing = .nothing
            }
        }
    }

    private func voiceChanged() {
        if voice.inConversation, !dashboard.isVisible {
            closeTask?.cancel()
            if showing != .everyday || !hovering { showing = .voice }
        } else if showing == .voice {
            // The conversation is over, or the dashboard has taken over showing it.
            scheduleClose(after: waitingAnswer == nil ? 1.2 : 12)
        }
    }

    // MARK: Everyday contents

    private func refresh() {
        // The dashboard's own figures, at most twice a minute.
        if Date().timeIntervalSince(lastRefresh) > 30 {
            lastRefresh = Date()
            dashboard.refresh()
        }
        Task { [weak self] in await self?.loadMusic() }
        Task { [weak self] in await self?.loadReminders() }
    }

    private func loadMusic() async {
        guard let music else {
            musicNote = nil
            track = nil
            return
        }
        guard case .read(let content, _)? = try? await music.run(tool: "spotify_now_playing", arguments: [:], access: ToolAccess()) else {
            track = nil
            musicNote = "Spotify could not be asked"
            return
        }
        track = NotchData.track(from: content)
        musicNote = track == nil ? content : nil
    }

    func music(_ action: String) {
        guard let music else { return }
        Task { [weak self] in
            _ = try? await music.run(tool: "spotify_control", arguments: ["action": action], access: ToolAccess())
            await self?.loadMusic()
        }
    }

    private func loadReminders() async {
        // Only if already allowed: the notch never makes macOS ask for a permission.
        guard let reminderStore, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let open = try? await reminderStore.open() else {
            reminders = []
            return
        }
        reminders = NotchData.dueToday(open)
    }

    func submitAsk() {
        let text = ask.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        dashboard.ask = text
        dashboard.submit()
        close()
    }

    func launch(_ entry: RegistryEntry) {
        dashboard.launch(entry)
        close()
    }
}
