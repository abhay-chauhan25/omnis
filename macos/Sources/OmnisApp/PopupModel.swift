import AppKit
import OmnisCore
import SwiftUI

/// Everything the popup shows, and what happens when a row is chosen.
@MainActor
final class PopupModel: ObservableObject {
    enum Row: Identifiable, Equatable {
        case entry(RegistryEntry)
        case ask(String)

        var id: String {
            switch self {
            case .entry(let entry): return entry.id
            case .ask: return "ask"
            }
        }
    }

    enum Phase: Equatable {
        case input
        case answering(text: String, finished: Bool, model: String?)
        case failed(String)
    }

    @Published var query = "" {
        didSet { if query != oldValue { queryChanged() } }
    }
    @Published private(set) var rows: [Row] = []
    @Published private(set) var selection = 0
    @Published private(set) var phase: Phase = .input
    /// Settings that were skipped when the registry was last loaded.
    @Published private(set) var notices: [String] = []
    /// Drives the entrance animation.
    @Published var visible = false
    /// Bumped each time the popup opens, so the view can take keyboard focus.
    @Published private(set) var openCount = 0

    /// Close the popup.
    var onDismiss: () -> Void = {}
    /// Reopen the popup to show a failure that happened after it closed.
    var onLateFailure: (String) -> Void = { _ in }

    private var registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
    private let backend: BackendService?
    private let audit: AuditLog
    private let performer: LaunchPerforming
    private var askTask: Task<Void, Never>?

    init(backend: BackendService?, audit: AuditLog) {
        self.backend = backend
        self.audit = audit
        self.performer = SystemLaunchPerformer(onLateFailure: { url, status in
            audit.record(action: "launch", kind: EntryKind.launcher.rawValue, target: url.lastPathComponent,
                         outcome: "error", detail: "exited with status \(status)")
        })
    }

    var editorName: String { registry.editor.name }

    // MARK: Lifecycle

    func prepareForOpen() {
        reloadRegistry()
        reset()
        openCount += 1
    }

    func reset() {
        askTask?.cancel()
        askTask = nil
        query = ""
        rows = []
        selection = 0
        phase = .input
    }

    func showFailure(_ message: String) {
        phase = .failed(message)
        announce("Problem: \(message)")
    }

    /// Speaks a change aloud for VoiceOver users.
    private func announce(_ message: String) {
        AccessibilityNotification.Announcement(message).post()
    }

    private func reloadRegistry() {
        do {
            let config = try ConfigStore.loadOrCreate(at: OmnisPaths.registryFile)
            registry = try Registry.load(config: config)
            notices = registry.warnings
        } catch {
            registry = Registry(entries: [], editor: RegistryConfig.standard.editor)
            notices = [error.localizedDescription]
        }
    }

    // MARK: Typing and selection

    private func queryChanged() {
        askTask?.cancel()
        askTask = nil
        phase = .input
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            rows = []
            selection = 0
            return
        }
        var next = Matcher.rank(query: trimmed, registry: registry).map { Row.entry($0.entry) }
        next.append(.ask(trimmed))
        rows = next
        selection = 0
    }

    func moveSelection(by delta: Int) {
        guard !rows.isEmpty, phase == .input else { return }
        selection = min(max(selection + delta, 0), rows.count - 1)
    }

    func runSelected() {
        guard phase == .input, rows.indices.contains(selection) else { return }
        run(rows[selection])
    }

    func run(_ row: Row) {
        switch row {
        case .entry(let entry): launch(entry)
        case .ask(let text): ask(text)
        }
    }

    // MARK: Actions

    private func launch(_ entry: RegistryEntry) {
        let executor = Executor(registry: registry, performer: performer)
        let audit = self.audit
        // Close at once; come back only if the launch fails.
        onDismiss()
        Task { [weak self] in
            do {
                try await executor.launch(entryID: entry.id)
                audit.record(action: "launch", kind: entry.kind.rawValue, target: entry.name, outcome: "ok")
            } catch {
                audit.record(action: "launch", kind: entry.kind.rawValue, target: entry.name,
                             outcome: "error", detail: error.localizedDescription)
                self?.onLateFailure("\(entry.name): \(error.localizedDescription)")
            }
        }
    }

    private func ask(_ text: String) {
        guard let backend else {
            phase = .failed("The OMNIS backend is not set up, so questions cannot be answered yet.")
            audit.record(action: "ask", outcome: "error", detail: "backend not configured")
            return
        }
        askTask?.cancel()
        phase = .answering(text: "", finished: false, model: nil)
        let audit = self.audit
        askTask = Task { [weak self] in
            var collected = ""
            do {
                for try await event in backend.ask(text) {
                    guard !Task.isCancelled, let self else { return }
                    switch event {
                    case .chunk(let piece):
                        collected += piece
                        self.phase = .answering(text: collected, finished: false, model: nil)
                    case .finished(let model):
                        self.phase = .answering(text: collected, finished: true, model: model)
                        audit.record(action: "ask", outcome: "ok", detail: model.map { "model \($0)" })
                        self.announce("Answer: \(collected)")
                    }
                }
            } catch {
                guard !Task.isCancelled else { return }
                // The backend's own error output helps explain a failed start.
                // It is written by the service, not copied from what was typed.
                let detail = [error.localizedDescription, backend.lastDiagnostic].compactMap { $0 }.joined(separator: " | ")
                audit.record(action: "ask", outcome: "error", detail: detail)
                self?.showFailure(error.localizedDescription)
            }
        }
    }
}
