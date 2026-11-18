import AppKit
import OmnisCore
import SwiftUI

/// Everything the chat window shows, and what happens when you send or launch.
@MainActor
final class ChatModel: ObservableObject {
    /// Where a question is answered. "Auto" lets OMNIS decide.
    enum Lane: String, CaseIterable, Identifiable {
        case auto, local, claude
        var id: String { rawValue }
        var title: String {
            switch self {
            case .auto: return "Auto"
            case .local: return "Local"
            case .claude: return "Claude"
            }
        }
    }

    @Published var input = "" {
        didSet { if input != oldValue { refreshSuggestions() } }
    }
    @Published private(set) var conversation = Conversation()
    /// Apps and projects matching what is typed, offered above the input.
    @Published private(set) var suggestions: [RegistryEntry] = []
    /// The suggestion Enter would launch, or nil if Enter sends a message.
    @Published private(set) var selectedSuggestion: Int?
    @Published var webEnabled = true
    @Published var lane: Lane = .auto
    /// A short line under the input: a launch result or a settings warning.
    @Published private(set) var notice: String?
    /// Bumped each time the window opens, so the view can take keyboard focus.
    @Published private(set) var openCount = 0
    /// Files waiting to go with the next message.
    @Published private(set) var pendingAttachments: [Attachment] = []

    private var registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
    private let backend: BackendService?
    private let audit: AuditLog
    private let ledger: UsageLedger
    private let performer: LaunchPerforming
    private var askTask: Task<Void, Never>?
    private var noticeTask: Task<Void, Never>?

    init(backend: BackendService?, audit: AuditLog, ledger: UsageLedger) {
        self.backend = backend
        self.audit = audit
        self.ledger = ledger
        self.performer = SystemLaunchPerformer(onLateFailure: { url, status in
            audit.record(action: "launch", kind: EntryKind.launcher.rawValue, target: url.lastPathComponent,
                         outcome: "error", detail: "exited with status \(status)")
        })
    }

    var editorName: String { registry.editor.name }
    var isAnswering: Bool { conversation.isAnswering }
    var canSend: Bool {
        let hasText = !input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        return (hasText || !pendingAttachments.isEmpty) && !isAnswering
    }

    // MARK: Lifecycle

    /// Called each time the window is shown. The conversation is kept.
    func prepareForOpen() {
        do {
            let config = try ConfigStore.loadOrCreate(at: OmnisPaths.registryFile)
            registry = try Registry.load(config: config)
            if let warning = registry.warnings.first { show(notice: warning, seconds: 6) }
        } catch {
            registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
            show(notice: error.localizedDescription, seconds: 6)
        }
        refreshSuggestions()
        openCount += 1
    }

    /// Forgets the conversation and starts again.
    func newChat() {
        askTask?.cancel()
        askTask = nil
        conversation.clear()
        input = ""
        notice = nil
        pendingAttachments = []
    }

    // MARK: Attachments

    /// Reads the chosen files and queues them for the next message. A file
    /// that cannot be read is reported and the rest are still attached.
    func attach(urls: [URL]) {
        for url in urls {
            do {
                try add(AttachmentLoader.load(url))
            } catch {
                show(notice: error.localizedDescription, seconds: 6)
                if case AttachmentError.tooMany = error { return }
            }
        }
    }

    func attachImage(data: Data, name: String) {
        do {
            try add([AttachmentLoader.image(from: data, name: name)])
        } catch {
            show(notice: error.localizedDescription, seconds: 6)
        }
    }

    private func add(_ attachments: [Attachment]) throws {
        for attachment in attachments {
            guard pendingAttachments.count < AttachmentLoader.maxAttachments else { throw AttachmentError.tooMany }
            pendingAttachments.append(attachment)
            if attachment.truncated {
                show(notice: "\u{201C}\(attachment.name)\u{201D} is long, so only the first part will be read.", seconds: 6)
            }
        }
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
        guard pasteboard.string(forType: .string) == nil else { return false }
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

    func launch(_ entry: RegistryEntry) {
        let executor = Executor(registry: registry, performer: performer)
        let audit = self.audit
        input = ""
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

        // The typed prefixes still work and win over the controls for one message.
        let options = RoutePrefix.split(text)
        var route = options.route != "auto" ? options.route : lane.rawValue
        var web = webEnabled && options.web

        // A file is personal: it is read by the model on this Mac, the chat
        // stays here, and nothing from it is put into a web search.
        if !attachments.isEmpty || conversation.hasFiles {
            route = "local"
            web = false
        }
        if !attachments.isEmpty {
            let images = attachments.filter { $0.kind == .image }.count
            audit.record(action: "attach", outcome: "ok",
                         detail: "\(images) image, \(attachments.count - images) document")
        }

        // Keeping one turn on this Mac keeps the whole chat here: otherwise a
        // later question would carry that turn to Claude as history.
        if route == "local" {
            conversation.keepLocal()
        } else if conversation.staysLocal {
            if route == "claude" {
                show(notice: "This chat is staying on this Mac. Start a new chat to use Claude.", seconds: 5)
            }
            route = "local"
        }
        let cloud = ledger.permission()

        let history = conversation.history()
        let answerID = conversation.begin(question: text, attachments: attachments)
        input = ""
        pendingAttachments = []

        guard let backend else {
            let reason = "The OMNIS backend is not set up, so questions cannot be answered yet."
            conversation.update(answerID) { $0.state = .failed(reason) }
            audit.record(action: "ask", outcome: "error", detail: "backend not configured")
            return
        }

        let audit = self.audit
        askTask = Task { [weak self] in
            do {
                for try await event in backend.ask(options.text, route: route, web: web, history: history, cloud: cloud,
                                                   attachments: attachments) {
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
                    case .usage(let model, let inputTokens, let outputTokens, let costUSD):
                        // Recorded turn by turn, so a stopped, failed or fallen-back
                        // answer still counts towards the month.
                        if !self.ledger.record(model: model, inputTokens: inputTokens,
                                               outputTokens: outputTokens, costUSD: costUSD) {
                            audit.record(action: "claude_usage", outcome: "error", detail: "usage record not written")
                        }
                    case .finished(let model, let details):
                        let warning = details.route == "cloud" ? self.ledger.warning() : nil
                        self.conversation.update(answerID) {
                            $0.state = .done
                            $0.sourceLine = Self.sourceLabel(model: model, details: details, budgetWarning: warning)
                        }
                        audit.record(action: "ask", outcome: "ok", detail: Self.auditDetail(model: model, details: details))
                        self.announce("Answer ready")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The backend's own error output helps explain a failed start.
                // It is written by the service, not copied from what was typed.
                let detail = [error.localizedDescription, backend.lastDiagnostic].compactMap { $0 }.joined(separator: " | ")
                audit.record(action: "ask", outcome: "error", detail: detail)
                self?.conversation.update(answerID) { $0.state = .failed(error.localizedDescription) }
                self?.announce("Problem: \(error.localizedDescription)")
            }
        }
    }

    /// Stops the answer being written. What arrived so far is kept.
    func stop() {
        guard let last = conversation.messages.last, last.state == .streaming else { return }
        askTask?.cancel()
        askTask = nil
        conversation.update(last.id) { $0.state = .stopped; $0.searching = false }
        audit.record(action: "ask", outcome: "stopped")
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
    static func sourceLabel(model: String?, details: AnswerDetails, budgetWarning: String? = nil) -> String? {
        guard let model else { return nil }
        var parts: [String] = []
        switch details.route {
        case "local":
            // Say first if Claude was wanted and could not be used.
            if let fallback = details.fallback { parts.append(fallback) }
            parts.append("\(model), on this Mac")
        case "cloud":
            parts.append(Self.claudeName(model))
            if let cost = details.costUSD { parts.append(Self.costText(cost)) }
        default:
            return model == "mock" ? "Mock reply, no model used" : "Answered by \(model)"
        }
        if (details.searches ?? 0) > 0 { parts.append("searched the web") }
        if let total = details.totalMilliseconds {
            parts.append(String(format: "%.1f s", Double(total) / 1000))
        }
        if let budgetWarning { parts.append(budgetWarning) }
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

    /// Small amounts are shown in cents so they do not all read as "$0.00".
    static func costText(_ dollars: Double) -> String {
        if dollars <= 0 { return "no charge" }
        if dollars < 0.01 { return String(format: "%.2f\u{00A2}", dollars * 100) }
        return String(format: "$%.2f", dollars)
    }

    /// Numbers only: which model, which route, how long, how many tokens, what it cost.
    static func auditDetail(model: String?, details: AnswerDetails) -> String {
        var parts = ["model \(model ?? "unknown")"]
        if let route = details.route { parts.append("route \(route)") }
        if let reason = details.reason { parts.append("why: \(reason)") }
        if let input = details.inputTokens { parts.append("in \(input) tokens") }
        if let output = details.outputTokens { parts.append("out \(output) tokens") }
        if let load = details.loadMilliseconds { parts.append("load \(load) ms") }
        if let total = details.totalMilliseconds { parts.append("total \(total) ms") }
        if let cost = details.costUSD { parts.append(String(format: "cost %.4f USD", cost)) }
        if let searches = details.searches, searches > 0 { parts.append("web searches \(searches)") }
        if let fallback = details.fallback { parts.append("fallback: \(fallback)") }
        return parts.joined(separator: ", ")
    }
}
