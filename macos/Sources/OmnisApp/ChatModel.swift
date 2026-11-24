import AppKit
import OmnisCore
import SwiftUI

/// Everything the chat window shows, and what happens when you send or launch.
@MainActor
final class ChatModel: ObservableObject {
    @Published var input = "" {
        didSet { if input != oldValue { refreshSuggestions() } }
    }
    @Published private(set) var conversation = Conversation()
    /// Apps and projects matching what is typed, offered above the input.
    @Published private(set) var suggestions: [RegistryEntry] = []
    /// The suggestion Enter would launch, or nil if Enter sends a message.
    @Published private(set) var selectedSuggestion: Int?
    @Published var webEnabled = true
    /// Which Claude model answers. Auto lets OMNIS choose per question.
    @Published var modelChoice: ModelChoice = .auto
    /// How hard the model thinks. Auto lets OMNIS choose per question.
    @Published var effortChoice: EffortChoice = .auto
    /// "Off the grid": everything is answered by the model on this Mac.
    @Published var offGrid = false {
        // Switching back to Claude also ends a chat's own move to this Mac.
        didSet { if !offGrid { chatLocal = false } }
    }
    /// This one chat was moved to the local model, after Claude could not be used.
    @Published private(set) var chatLocal = false
    /// How much of the Claude plan has been used, as last reported.
    @Published private(set) var usage = UsageWindows()
    /// A short line under the input: a launch result or a settings warning.
    @Published private(set) var notice: String?
    /// Bumped each time the window opens, so the view can take keyboard focus.
    @Published private(set) var openCount = 0
    /// Files waiting to go with the next message.
    @Published private(set) var pendingAttachments: [Attachment] = []

    private var registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
    private let backend: BackendService?
    private let audit: AuditLog
    private let performer: LaunchPerforming
    private let calendarWriter: (any CalendarWriting)?
    private let claude: ClaudeService?
    private let projectSetup: ProjectSetup?
    private let services: [any AssistantTools]
    let limits = UsageLimits()
    /// When the window was last hidden, to end a chat left alone for a long time.
    private var hiddenAt: Date?
    static let idleChatSeconds: TimeInterval = 25 * 60
    /// Opens a project in project mode. Set by the app once the dashboard exists.
    var openProjectMode: ((RegistryEntry, _ resume: Bool) -> Void)?

    /// Handles "continue VoyagerAI in project mode" and the like. True if it did.
    private func openedProjectMode(for text: String) -> Bool {
        guard let openProjectMode, let request = ProjectModeRequest.parse(text, registry: registry) else { return false }
        openProjectMode(request.project, request.resume)
        audit.record(action: "project_mode", target: request.project.name, outcome: "ok", detail: request.resume ? "resume" : "open")
        show(notice: "Opened \(request.project.name) in project mode", seconds: 3)
        return true
    }

    /// Opens the project a finished set-up created, in project mode.
    func openInProjectMode(_ proposalID: UUID) {
        guard let plan = conversation.project(proposalID)?.plan else { return }
        reloadRegistry()
        guard let entry = registry.entries.first(where: { $0.kind == .project && $0.url.standardizedFileURL == plan.folder.standardizedFileURL }) else {
            show(notice: "\(plan.name) is not in your projects folder any more.", seconds: 5)
            return
        }
        openProjectMode?(entry, false)
    }
    private static let usageKey = "OMNISClaudeUsage"
    private var askTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(backend: BackendService?, audit: AuditLog, calendarWriter: (any CalendarWriting)? = nil,
         claude: ClaudeService? = nil, projectSetup: ProjectSetup? = nil, services: [any AssistantTools] = []) {
        self.backend = backend
        self.services = services
        self.projectSetup = projectSetup
        self.claude = claude
        self.calendarWriter = calendarWriter
        self.audit = audit
        self.performer = SystemLaunchPerformer(onLateFailure: { url, status in
            audit.record(action: "launch", kind: EntryKind.launcher.rawValue, target: url.lastPathComponent,
                         outcome: "error", detail: "exited with status \(status)")
        })
        // Marked through its own path, not the answer stream: pressing Stop at
        // the wrong instant must not leave a chat with calendar text unmarked.
        backend?.onPersonalDataDelivered { [weak self] in
            Task { @MainActor in self?.conversation.markPersonal() }
        }
        claude?.onPersonalDataDelivered { [weak self] in
            Task { @MainActor in self?.conversation.markPersonal() }
        }
        // The last figures are kept between runs, so they show at once and
        // the limits apply from the first question. A window that has since
        // reset is ignored when they are read.
        if let saved = UserDefaults.standard.data(forKey: Self.usageKey),
           let windows = try? JSONDecoder().decode(UsageWindows.self, from: saved) {
            usage = windows.current()
        }
        // Requests the gate refused or held back. Tool names and reasons only.
        claude?.onGate { action, tool, outcome, detail in
            audit.record(action: action, target: tool, outcome: outcome, detail: detail)
        }
        claude?.onUsage { [weak self] windows in
            Task { @MainActor in
                guard let self else { return }
                // A report may cover only one window; the other keeps its last value.
                var merged = self.usage.current()
                if windows.fiveHour != nil { merged.fiveHour = windows.fiveHour; merged.fiveHourResets = windows.fiveHourResets }
                if windows.sevenDay != nil { merged.sevenDay = windows.sevenDay; merged.sevenDayResets = windows.sevenDayResets }
                self.usage = merged
                if let data = try? JSONEncoder().encode(merged) { UserDefaults.standard.set(data, forKey: Self.usageKey) }
            }
        }
    }

    var editorName: String { registry.editor.name }
    /// True when questions are answered by the model on this Mac, not by Claude.
    var usesLocal: Bool { offGrid || chatLocal || claude == nil }
    /// True when this chat cannot search the web: only on this Mac, where a
    /// file or the calendar in a chat keeps its contents out of searches.
    var webBlockedByFile: Bool { usesLocal && (conversation.hasPersonalData || !pendingAttachments.isEmpty) }
    /// "5h 8% · 7d 2%", shown while Claude is in use.
    var usageLabel: String? { usesLocal ? nil : usage.label() }
    /// True when usage is within ten points of where ordinary chats stop.
    var usageIsHigh: Bool {
        let live = usage.current()
        return (live.fiveHour ?? 0) >= limits.fiveHour - 0.10 || (live.sevenDay ?? 0) >= limits.sevenDay - 0.10
    }
    var isAnswering: Bool { conversation.isAnswering }
    var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingAttachments.isEmpty) && !isAnswering
    }

    // MARK: Lifecycle

    /// Called each time the window is shown. The conversation is kept.
    func prepareForOpen() {
        // A chat left with the window closed for a long time is over.
        if let hiddenAt, Date().timeIntervalSince(hiddenAt) >= Self.idleChatSeconds, !isAnswering, !conversation.isEmpty {
            newChat()
        }
        hiddenAt = nil
        reloadRegistry()
        openCount += 1
    }

    /// Reads the list of apps, projects and launchers again. Called whenever
    /// a window opens, so an edit to the registry is picked up.
    func reloadRegistry() {
        do {
            let config = try ConfigStore.loadOrCreate(at: OmnisPaths.registryFile)
            registry = try Registry.load(config: config)
            if let warning = registry.warnings.first { show(notice: warning, seconds: 6) }
        } catch {
            registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
            show(notice: error.localizedDescription, seconds: 6)
        }
        refreshSuggestions()
    }

    /// Everything that can be launched, for the dashboard's tiles.
    var registryEntries: [RegistryEntry] { registry.entries }
    var currentRegistry: Registry { registry }

    /// A question typed on the dashboard. It is handled like one typed here:
    /// a clear request to open something is launched without asking a model,
    /// a typed command changes a setting, and anything else is asked. What is
    /// being typed in this window, and files waiting here, are left alone.
    func askFromDashboard(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isAnswering else { return }
        if openedProjectMode(for: trimmed) { return }
        let suggestion = LaunchSuggestion.suggest(for: trimmed, registry: registry)
        if suggestion.preselect, let entry = suggestion.entries.first {
            launch(entry, clearInput: false)
        } else if let command = SlashCommand.parse(trimmed) {
            apply(command)
        } else {
            ask(trimmed, attachments: [], onThisMac: false)
        }
    }

    /// Called when the window is hidden. The conversation is kept for now.
    func windowHidden() {
        hiddenAt = Date()
    }

    /// Forgets the conversation and starts again.
    func newChat() {
        askTask?.cancel()
        askTask = nil
        claude?.endSession()
        chatLocal = false
        conversation.clear()
        input = ""
        notice = nil
        pendingAttachments = []
    }

    // MARK: Attachments

    /// Reads the chosen files and queues them for the next message. A file
    /// that cannot be read is reported and the rest are still attached.
    /// Reading happens off the main thread, so a large PDF does not freeze the window.
    func attach(urls: [URL]) {
        guard !urls.isEmpty else { return }
        show(notice: "Reading\u{2026}", seconds: 30)
        Task { [weak self] in
            for url in urls.prefix(AttachmentLoader.maxAttachments + 1) {
                let result = await Task.detached(priority: .userInitiated) {
                    Result { try AttachmentLoader.load(url) }
                }.value
                guard let self else { return }
                if self.notice == "Reading\u{2026}" { self.notice = nil }
                switch result {
                case .success(let attachments):
                    if !self.add(attachments) { return }
                case .failure(let error):
                    self.show(notice: error.localizedDescription, seconds: 6)
                }
            }
        }
    }

    func attachImage(data: Data, name: String) {
        Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                Result { try AttachmentLoader.image(from: data, name: name) }
            }.value
            switch result {
            case .success(let attachment): _ = self?.add([attachment])
            case .failure(let error): self?.show(notice: error.localizedDescription, seconds: 6)
            }
        }
    }

    /// Queues what fits within the limits and says what did not. Returns
    /// false once the message is full.
    @discardableResult
    private func add(_ attachments: [Attachment]) -> Bool {
        let outcome = AttachmentLimits.fit(attachments, alongside: pendingAttachments)
        pendingAttachments.append(contentsOf: outcome.accepted)
        if let note = outcome.note { show(notice: note, seconds: 7) }
        return !outcome.full
    }

    func removeAttachment(_ id: UUID) {
        pendingAttachments.removeAll { $0.id == id }
    }

    /// The "+" button: choose files to attach.
    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.image, .pdf, .text, .sourceCode, .json, .xml, .yaml]
        panel.message = "Choose images, PDFs or text files. They are read on this Mac and are not sent to Claude."
        panel.prompt = "Attach"
        panel.level = .modalPanel  // above the chat window, which floats
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK else { return }
        attach(urls: panel.urls)
    }

    /// Command-V: if the clipboard holds a picture or files, attach them.
    /// Returns false for ordinary text, so that pastes as usual.
    func attachFromPasteboard() -> Bool {
        let pasteboard = NSPasteboard.general
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self],
                                             options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            attach(urls: urls)
            return true
        }
        // Text on the clipboard pastes as text. The exception is a lone web
        // address, which is what a browser adds when you copy a picture.
        if let string = pasteboard.string(forType: .string) {
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            let loneAddress = !trimmed.contains(where: \.isWhitespace)
                && (trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://"))
            guard loneAddress else { return false }
        }
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            if let data = pasteboard.data(forType: type) {
                attachImage(data: data, name: "Pasted image")
                return true
            }
        }
        return false
    }

    // MARK: Typing

    private func refreshSuggestions() {
        let suggestion = LaunchSuggestion.suggest(for: input, registry: registry)
        suggestions = suggestion.entries
        selectedSuggestion = suggestion.preselect ? 0 : nil
    }

    /// Up moves into the suggestions; down past the last one goes back to "send as a message".
    func moveSelection(by delta: Int) {
        guard !suggestions.isEmpty else { return }
        switch (selectedSuggestion, delta) {
        case (nil, let step) where step < 0: selectedSuggestion = suggestions.count - 1
        case (nil, _): break
        case (let current?, let step):
            let next = current + step
            selectedSuggestion = next < 0 ? 0 : (next >= suggestions.count ? nil : next)
        }
    }

    /// Enter: launch the selected suggestion, or send the text.
    func submit() {
        if let index = selectedSuggestion, suggestions.indices.contains(index) {
            launch(suggestions[index])
        } else {
            send()
        }
    }

    // MARK: Launching

    func launch(_ entry: RegistryEntry, clearInput: Bool = true) {
        let executor = Executor(registry: registry, performer: performer)
        let audit = self.audit
        if clearInput { input = "" }
        Task { [weak self] in
            do {
                try await executor.launch(entryID: entry.id)
                audit.record(action: "launch", kind: entry.kind.rawValue, target: entry.name, outcome: "ok")
                self?.show(notice: "Opened \(entry.name)", seconds: 2.5)
            } catch {
                audit.record(action: "launch", kind: entry.kind.rawValue, target: entry.name,
                             outcome: "error", detail: error.localizedDescription)
                self?.show(notice: "\(entry.name): \(error.localizedDescription)", seconds: 8)
            }
        }
    }

    private func show(notice text: String, seconds: Double) {
        notice = text
        announce(text)
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            if self?.notice == text { self?.notice = nil }
        }
    }

    // MARK: Asking

    func send() {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        let attachments = pendingAttachments
        guard !text.isEmpty || !attachments.isEmpty, !isAnswering else { return }

        // "Continue VoyagerAI in project mode" opens it there, with no model involved.
        if attachments.isEmpty, openedProjectMode(for: text) {
            input = ""
            return
        }
        // A typed command such as "/effort high" changes a setting and is not sent to a model.
        if attachments.isEmpty, let command = SlashCommand.parse(text) {
            input = ""
            apply(command)
            return
        }
        input = ""
        pendingAttachments = []
        ask(text, attachments: attachments, onThisMac: false)
    }

    private func apply(_ command: SlashCommand) {
        switch command {
        case .model(let choice):
            modelChoice = choice
            show(notice: "Model: \(choice.title)", seconds: 3)
        case .effort(let choice):
            effortChoice = choice
            show(notice: "Effort: \(choice.title)", seconds: 3)
        case .local(let on):
            offGrid = on
            if !on { chatLocal = false }
            show(notice: on ? "Off the grid: questions are answered on this Mac." : "Back to Claude.", seconds: 4)
        case .unknown(let help):
            show(notice: help, seconds: 8)
        }
    }

    /// Answers again on this Mac, after Claude could not be used. The rest of this chat stays here.
    func answerLocally(_ answerID: UUID) {
        guard !isAnswering, let index = conversation.messages.firstIndex(where: { $0.id == answerID }), index > 0 else { return }
        let question = conversation.messages[index - 1]
        guard question.role == .user else { return }
        chatLocal = true
        conversation.update(answerID) { $0.offersLocal = false }
        ask(question.text, attachments: question.attachments, onThisMac: true)
    }

    private func ask(_ text: String, attachments: [Attachment], onThisMac: Bool) {
        // The typed prefixes still work for one message.
        let options = RoutePrefix.split(text)
        let local = onThisMac || usesLocal || options.route == "local"
        if local, options.route == "claude" {
            show(notice: claude == nil ? "Claude Code was not found, so this is answered on this Mac."
                 : "This is being answered on this Mac. Type /local off to use Claude.", seconds: 6)
        }
        if !attachments.isEmpty {
            let images = attachments.filter { $0.kind == .image }.count
            audit.record(action: "attach", outcome: "ok",
                         detail: "\(images) image, \(attachments.count - images) document")
        }
        // The model may prepare a calendar change only when your own message asks for one.
        // Deleting is held to a stricter rule; see `Conversation.offer`.
        let offer = calendarWriter == nil ? ChangeOffer()
            : conversation.offer(for: options.text, hasAttachments: !attachments.isEmpty)
        let history = conversation.history()
        let answerID = conversation.begin(question: text, attachments: attachments)

        func fail(_ reason: String, log: String, offerLocal: Bool = false) {
            conversation.update(answerID) { $0.state = .failed(reason); $0.offersLocal = offerLocal }
            self.audit.record(action: "ask", outcome: "error", detail: log)
            announce("Problem: \(reason)")
        }

        let stream: AsyncThrowingStream<AnswerEvent, Error>
        if local {
            guard let backend else {
                fail("The model on this Mac is not set up, so questions cannot be answered here yet.", log: "backend not configured")
                return
            }
            // On this Mac, a chat that holds a file or the calendar does not
            // search the web, so none of it can end up in a search.
            let personal = conversation.hasPersonalData || PersonalIntent.mentionsCalendar(options.text)
            let web = webEnabled && options.web && !conversation.hasPersonalData
            conversation.keepLocal()
            stream = backend.ask(options.text, route: "local", web: web, history: history, attachments: attachments,
                                 personal: personal, calendar: true, calendarWrite: offer.changes, deletes: offer.deletes)
        } else {
            guard let claude else { return }
            // Ordinary chats leave part of the Claude plan for your own work.
            if let hit = limits.hit(by: usage) {
                fail(hit.message, log: "claude usage limit", offerLocal: backend != nil)
                return
            }
            let choice = ClaudeRouter.choose(text: options.text, hasDocument: attachments.contains { $0.kind == .text },
                                             model: modelChoice, effort: effortChoice)
            var request = ClaudeRequest(
                text: options.text, history: history, attachments: attachments, model: choice.model, effort: choice.effort,
                reason: choice.reason, web: webEnabled && options.web,
                access: CalendarToolAccess(calendar: true, write: offer.changes, deletes: offer.deletes)
            )
            // A new project may be prepared only when your own message asks for one.
            // Deleting through any service needs your own message to have asked for it.
            request.toolAccess = conversation.serviceAccess(for: options.text)
            // Once the chat holds something personal, a search outside is asked about first, once.
            request.sensitive = conversation.hasPersonalData
            request.searchConsent = conversation.searchConsent
            request.allowProject = projectSetup != nil && attachments.isEmpty && conversation.offersProject(for: options.text)
            stream = claude.ask(request)
        }

        let audit = self.audit
        let backend = self.backend
        askTask = Task { [weak self] in
            do {
                for try await event in stream {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case .chunk(let piece):
                        self.conversation.update(answerID) { $0.text += piece }
                    case .searching(let query):
                        self.conversation.update(answerID) { $0.searching = true; $0.searchQueries.append(query) }
                        self.announce("Searching the web")
                    case .sources(let results):
                        self.conversation.update(answerID) { $0.searching = false; $0.sources = results }
                        // Counts only. The search terms are never logged.
                        audit.record(action: "web_search", outcome: "ok", detail: "\(results.count) results")
                    case .searchFailed(let why):
                        self.conversation.update(answerID) { $0.searching = false; $0.searchProblem = why }
                        audit.record(action: "web_search", outcome: "error", detail: why)
                    case .searchConsentNeeded(let query):
                        self.conversation.update(answerID) { $0.searchAsk = SearchAsk(query: query) }
                        self.announce("OMNIS is asking whether this chat may search the web")
                    case .searchConsentLapsed:
                        self.conversation.lapseSearchAsk()
                    case .readingCalendar:
                        self.conversation.update(answerID) { $0.readingCalendar = true }
                        self.announce("Checking your calendar")
                    case .calendarRead(let summary, let events):
                        // From here the chat holds calendar information.
                        self.conversation.markPersonal()
                        let note = events < 0 ? summary : "\(summary): \(events == 1 ? "1 event" : "\(events) events")"
                        self.conversation.update(answerID) { $0.readingCalendar = false; $0.calendarNotes.append(note) }
                        // Counts only. No event's title, time or place is logged.
                        audit.record(action: "calendar_read", outcome: "ok", detail: events < 0 ? "details" : "\(events) events")
                    case .calendarFailed(let why):
                        self.conversation.update(answerID) { $0.readingCalendar = false; $0.calendarProblem = why }
                        audit.record(action: "calendar_read", outcome: "error", detail: why)
                    case .changeProposed(let change):
                        // Shown as a preview only. It is carried out in `confirm`,
                        // which nothing but the user's click calls.
                        let proposal = EventProposal(change: change)
                        self.conversation.add(proposal, to: answerID)
                        // The kind of change only. No title, time, place or name.
                        audit.record(action: "calendar_propose", outcome: "ok", detail: change.kind)
                        self.announce("\(change.heading) ready to check")
                        if case .create(let draft) = change, draft.calendarName == nil {
                            self.fillCalendarName(for: proposal.id)
                        }
                    case .actionProposed(let action):
                        // A preview only. It is carried out in `confirmAction`, on the user's click.
                        self.conversation.add(action, to: answerID)
                        audit.record(action: "\(action.service)_propose", outcome: "ok", detail: action.kind)
                        self.announce("\(action.heading) ready to check")
                    case .serviceNote(let note):
                        self.conversation.update(answerID) { if !$0.serviceNotes.contains(note) { $0.serviceNotes.append(note) } }
                        audit.record(action: "service", outcome: "ok", detail: note)
                    case .projectProposed(let plan):
                        // A preview only. It is set up in `confirmProject`, on the user's click.
                        self.conversation.add(ProjectProposal(plan: plan), to: answerID)
                        audit.record(action: "project_propose", outcome: "ok")
                        self.announce("New project ready to check")
                    case .eventRefused(let why):
                        self.conversation.update(answerID) { $0.proposalProblem = why }
                        // The reason can name a calendar, so it is not logged.
                        audit.record(action: "calendar_propose", outcome: "refused")
                    case .finished(let model, let details):
                        self.conversation.update(answerID) {
                            $0.state = .done
                            $0.searching = false
                            $0.readingCalendar = false
                            $0.sourceLine = Self.sourceLabel(model: model, details: details)
                        }
                        audit.record(action: "ask", outcome: "ok", detail: Self.auditDetail(model: model, details: details))
                        self.announce("Answer ready")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The local service's own error output helps explain a failed start.
                // It is written by the service, not copied from what was typed.
                let extra = local ? backend?.lastDiagnostic : nil
                audit.record(action: "ask", outcome: "error",
                             detail: [error.localizedDescription, extra].compactMap { $0 }.joined(separator: " | "))
                // If Claude cannot be used, the model on this Mac is offered.
                let offerLocal = !local && backend != nil && error is ClaudeError && (error as? ClaudeError) != .busy
                self?.conversation.lapseSearchAsk()
                self?.conversation.update(answerID) {
                    $0.state = .failed(error.localizedDescription)
                    $0.searching = false
                    $0.readingCalendar = false
                    $0.offersLocal = offerLocal
                }
                self?.announce("Problem: \(error.localizedDescription)")
            }
        }
    }

    /// The user's answer to "may this chat search the web?". It holds for the
    /// rest of the chat, and an answer that was waiting for it carries on.
    func answerSearchAsk(_ allowed: Bool) {
        guard conversation.messages.contains(where: { $0.searchAsk?.state == .waiting }) else { return }
        conversation.settleSearch(allowed: allowed)
        claude?.answerSearchConsent(allowed)
        audit.record(action: "search_consent", outcome: allowed ? "allowed" : "declined", detail: "for the rest of the chat")
    }

    /// Stops the answer being written. What arrived so far is kept.
    func stop() {
        guard let last = conversation.messages.last, last.state == .streaming else { return }
        askTask?.cancel()
        askTask = nil
        conversation.lapseSearchAsk()
        conversation.update(last.id) { $0.state = .stopped; $0.searching = false; $0.readingCalendar = false }
        audit.record(action: "ask", outcome: "stopped")
    }

    // MARK: Calendar events

    /// Carries out a previewed change to the calendar. Called only by the
    /// user's click on that preview. It works once per preview, and only
    /// while the preview is waiting or after a failed try.
    func confirm(_ proposalID: UUID) {
        guard let calendarWriter, let change = conversation.beginSaving(proposalID) else { return }
        let audit = self.audit
        Task { [weak self] in
            do {
                let result = try await calendarWriter.apply(change)
                // The kind of change and the outcome only.
                audit.record(action: "calendar_change", outcome: "ok", detail: change.kind)
                self?.conversation.updateProposal(proposalID) { $0.state = .done(result) }
                self?.announce(result)
            } catch {
                // A fixed word for the reason: the full text can name a calendar.
                audit.record(action: "calendar_change", outcome: "error",
                             detail: "\(change.kind): \((error as? CalendarError)?.code ?? "error")")
                self?.conversation.updateProposal(proposalID) { $0.state = .failed(error.localizedDescription) }
                self?.announce("The calendar was not changed")
            }
        }
    }

    // MARK: Changes from other services

    /// Carries out a previewed change from a service. Called only by the
    /// user's click on that preview, once.
    func confirmAction(_ id: UUID) {
        guard let action = conversation.beginAction(id), let provider = services.first(where: { $0.service == action.service }) else { return }
        let audit = self.audit
        Task { [weak self] in
            do {
                let result = try await provider.perform(action)
                // The kind of change and the outcome only.
                audit.record(action: "\(action.service)_change", outcome: "ok", detail: action.kind)
                self?.conversation.updateAction(id) { $0.state = .done(result) }
                self?.announce(result)
            } catch {
                audit.record(action: "\(action.service)_change", outcome: "error", detail: action.kind)
                self?.conversation.updateAction(id) { $0.state = .failed(error.localizedDescription) }
                self?.announce("Nothing was changed")
            }
        }
    }

    func declineAction(_ id: UUID) {
        guard let action = conversation.action(id), conversation.declineAction(id) else { return }
        audit.record(action: "\(action.service)_change", outcome: "declined", detail: action.kind)
    }

    // MARK: New projects

    /// Sets up a previewed project: folder, git, GitHub repository, editor.
    /// Called only by the user's click on that preview, and only once.
    func confirmProject(_ proposalID: UUID) {
        guard let projectSetup, let plan = conversation.beginProject(proposalID) else { return }
        let audit = self.audit
        Task { [weak self] in
            do {
                try await projectSetup.perform(plan) { step in
                    Task { @MainActor in self?.conversation.updateProject(proposalID) { $0.progress = step } }
                }
                // The name of the project is the user's own and is recorded like any launch target.
                audit.record(action: "project_create", target: plan.name, outcome: "ok", detail: plan.visibility.rawValue)
                guard let self else { return }
                self.reloadRegistry()
                var result = "Created \(plan.repository) and pushed the first commit"
                if let entry = self.registry.entries.first(where: { $0.kind == .project && $0.url.standardizedFileURL == plan.folder.standardizedFileURL }) {
                    self.launch(entry, clearInput: false)
                    result += ". Opening it in \(self.registry.editor.name)"
                }
                self.conversation.updateProject(proposalID) { $0.state = .done(result); $0.progress = nil }
                self.announce("Project created")
            } catch {
                audit.record(action: "project_create", target: plan.name, outcome: "error", detail: error.localizedDescription)
                self?.conversation.updateProject(proposalID) { $0.state = .failed(error.localizedDescription); $0.progress = nil }
                self?.announce("The project was not fully set up")
            }
        }
    }

    func declineProject(_ proposalID: UUID) {
        guard conversation.declineProject(proposalID) else { return }
        audit.record(action: "project_create", outcome: "declined")
    }

    /// The user chose not to add a previewed event.
    func decline(_ proposalID: UUID) {
        guard conversation.declineProposal(proposalID) else { return }
        audit.record(action: "calendar_change", outcome: "declined")
    }

    /// Looks up which calendar the event would go into, to show on the preview.
    private func fillCalendarName(for proposalID: UUID) {
        guard let calendarWriter else { return }
        Task { [weak self] in
            guard let name = try? await calendarWriter.defaultCalendarName() else { return }
            self?.conversation.updateProposal(proposalID) { $0.calendarName = name }
        }
    }

    /// Opens a search source in the browser. Only ordinary web pages, and
    /// only ones that are listed under an answer in this conversation.
    func open(_ source: SearchResult) {
        guard conversation.messages.contains(where: { $0.sources.contains(source) }),
              source.url.scheme?.lowercased() == "https" else { return }
        NSWorkspace.shared.open(source.url)
        audit.record(action: "open_source", target: source.host, outcome: "ok")
    }

    /// Speaks a change aloud for VoiceOver users.
    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    // MARK: Labels

    /// The "which model answered" line under an answer.
    static func sourceLabel(model: String?, details: AnswerDetails) -> String? {
        guard let model else { return nil }
        var parts: [String] = []
        switch details.route {
        case "local":
            parts.append("\(model), on this Mac")
        case "claude":
            parts.append(Self.claudeName(model))
        default:
            return model == "mock" ? "Mock reply, no model used" : "Answered by \(model)"
        }
        if (details.searches ?? 0) > 0 { parts.append("searched the web") }
        if (details.calendarReads ?? 0) > 0 { parts.append("read your calendar") }
        if let total = details.totalMilliseconds {
            parts.append(String(format: "%.1f s", Double(total) / 1000))
        }
        return parts.joined(separator: " \u{00B7} ")
    }

    static func claudeName(_ model: String) -> String {
        switch model {
        case "claude-haiku-5-5": return "Claude Haiku 5.5"
        case "claude-sonnet-5-5": return "Claude Sonnet 5.5"
        case "claude-opus-5-5": return "Claude Opus 5.5"
        default: return model
        }
    }

    /// Numbers only: which model, which route, how long, how many tokens.
    static func auditDetail(model: String?, details: AnswerDetails) -> String {
        var parts = ["model \(model ?? "unknown")"]
        if let route = details.route { parts.append("route \(route)") }
        if let reason = details.reason { parts.append("why: \(reason)") }
        if let input = details.inputTokens { parts.append("in \(input) tokens") }
        if let output = details.outputTokens { parts.append("out \(output) tokens") }
        if let load = details.loadMilliseconds { parts.append("load \(load) ms") }
        if let total = details.totalMilliseconds { parts.append("total \(total) ms") }
        if let searches = details.searches, searches > 0 { parts.append("web searches \(searches)") }
        if let reads = details.calendarReads, reads > 0 { parts.append("calendar reads \(reads)") }
        return parts.joined(separator: ", ")
    }
}
