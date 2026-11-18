import Foundation

/// How to start the backend: a program, its arguments, and where to run it.
public struct BackendConfig: Sendable {
    public var executable: URL
    public var arguments: [String]
    public var workingDirectory: URL
    public var environment: [String: String]?
    /// How long a freshly started backend has to say hello before it is
    /// treated as broken and stopped.
    public var helloTimeout: TimeInterval
    /// How long a web search may take before the app gives up on it. Kept
    /// shorter than the backend's own wait (70 s).
    public var searchDeadline: TimeInterval = 50
    /// Extra environment for the backend, read each time it starts. Used to
    /// hand over the Claude key from the Keychain without storing it anywhere.
    public var secrets: (@Sendable () -> [String: String])?

    public init(
        executable: URL,
        arguments: [String],
        workingDirectory: URL,
        environment: [String: String]? = nil,
        helloTimeout: TimeInterval = 10
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.environment = environment
        self.helloTimeout = helloTimeout
    }

    /// The standard way to run the Python service from a checkout of the repo.
    /// With `ollama` set, questions go to local models and the model server is
    /// started on demand; without it, the service gives canned mock replies.
    public static func python(
        _ python: URL,
        backendDirectory: URL,
        ollama: URL? = nil,
        idleSeconds: Double = 300
    ) -> BackendConfig {
        var arguments = ["-m", "omnis_backend", "--idle-seconds", String(idleSeconds)]
        if let ollama {
            arguments += ["--engine", "local", "--ollama-bin", ollama.path, "--keep-alive-seconds", String(idleSeconds)]
        }
        return BackendConfig(executable: python, arguments: arguments, workingDirectory: backendDirectory)
    }
}

public enum BackendError: Error, Equatable, LocalizedError {
    case launchFailed(String)
    case serviceStopped
    case service(code: String, message: String)
    case protocolViolation(String)
    case questionTooLong

    public var errorDescription: String? {
        switch self {
        case .launchFailed(let why): return "The OMNIS backend could not start: \(why)"
        case .serviceStopped: return "The OMNIS backend stopped before it finished answering."
        case .service(_, let message): return "The OMNIS backend reported a problem: \(message)"
        case .protocolViolation(let why): return "The OMNIS backend sent something unexpected: \(why)"
        case .questionTooLong: return "That question is too long to send."
        }
    }
}

public enum AnswerEvent: Equatable, Sendable {
    case chunk(String)
    /// The model asked for a web search and the app is running it.
    case searching(query: String)
    /// The search finished and these results were given to the model.
    case sources([SearchResult])
    /// The search could not be done; the model was told so.
    case searchFailed(String)
    case finished(model: String?, details: AnswerDetails)
}

/// Starts the backend only when a question is asked, talks to it over pipes,
/// and copes with it stopping (idle timeout or crash).
public final class BackendService: @unchecked Sendable {
    private struct Pending {
        let text: String
        let route: String
        let web: Bool
        let history: [ChatTurn]
        let cloud: CloudPermission
        let continuation: AsyncThrowingStream<AnswerEvent, Error>.Continuation
        var receivedAny = false
        var retried = false
        /// True once the question has been written to the current process.
        var sent = false
    }

    /// Longest question accepted, matching `MAX_TEXT_CHARS` in the Python service.
    public static let maxQuestionLength = 100_000
    private static let maxDisplayLength = 500

    private let config: BackendConfig
    private let queue = DispatchQueue(label: "omnis.backend")

    // All of the following are touched only on `queue`.
    private var process: Process?
    private var input: FileHandle?
    private var generation = 0
    private var buffer = Data()
    private var pending: [String: Pending] = [:]
    private var starts = 0
    private var diagnostic = ""
    private var greeted = false

    private let webSearch: (any WebSearching)?

    /// `webSearch` is what carries out a search when the model asks for one.
    /// Without it, the model is told that web search is unavailable.
    public init(config: BackendConfig, webSearch: (any WebSearching)? = nil) {
        self.config = config
        self.webSearch = webSearch
        // Writing to a backend that has just exited must raise an error, not kill the app.
        signal(SIGPIPE, SIG_IGN)
    }

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    // MARK: Public surface

    public var isRunning: Bool { queue.sync { process?.isRunning ?? false } }

    /// How many times the backend process has been started.
    public var startCount: Int { queue.sync { starts } }

    public var processIdentifier: Int32? {
        queue.sync { (process?.isRunning ?? false) ? process?.processIdentifier : nil }
    }

    /// The last thing the backend wrote to its error output, for troubleshooting.
    public var lastDiagnostic: String? {
        queue.sync { diagnostic.isEmpty ? nil : diagnostic }
    }

    /// Sends a question. Pieces of the answer arrive on the returned stream.
    /// Dropping or cancelling the stream cancels the request.
    /// `history` is the earlier turns of the conversation, oldest first.
    public func ask(
        _ text: String,
        route: String = "auto",
        web: Bool = true,
        history: [ChatTurn] = [],
        cloud: CloudPermission = CloudPermission()
    ) -> AsyncThrowingStream<AnswerEvent, Error> {
        let id = UUID().uuidString
        return AsyncThrowingStream { continuation in
            guard text.count <= Self.maxQuestionLength else {
                continuation.finish(throwing: BackendError.questionTooLong)
                return
            }
            continuation.onTermination = { [weak self] reason in
                if case .cancelled = reason { self?.cancel(id) }
            }
            queue.async {
                self.pending[id] = Pending(text: text, route: route, web: web, history: history, cloud: cloud, continuation: continuation)
                self.send(id)
            }
        }
    }

    /// Stops the backend now. Any unfinished answers end with an error.
    public func stop() {
        queue.sync {
            generation += 1
            let old = process
            process = nil
            try? input?.close()
            input = nil
            buffer.removeAll()
            old?.terminationHandler = nil
            if old?.isRunning == true { old?.terminate() }
            failAll(BackendError.serviceStopped)
        }
    }

    // MARK: Internals (always on `queue`)

    private func send(_ id: String) {
        guard let request = pending[id] else { return }
        do {
            try ensureRunning()
            // Marked before writing: from here the request belongs to this
            // process, and the exit handling will retry or fail it.
            pending[id]?.sent = true
            try write(.ask(id: id, text: request.text, route: request.route, web: request.web, history: request.history,
                           cloud: request.cloud))
        } catch let error as BackendError {
            finish(id, throwing: error)
        } catch {
            // The pipe closed under us (the backend is exiting or gone).
            guard let process else {
                finish(id, throwing: BackendError.serviceStopped)
                return
            }
            // Hand the request to the exit handling, and make sure an exit
            // really happens so it cannot be left waiting.
            pending[id]?.sent = true
            if process.isRunning { process.terminate() }
        }
    }

    private func cancel(_ id: String) {
        queue.async {
            guard self.pending.removeValue(forKey: id) != nil else { return }
            try? self.write(.cancel(id: id))
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }

        // The old process has exited but its exit notice has not been handled
        // yet. Settle its requests now, or they would be orphaned.
        let resend = process == nil ? [] : reapStoppedProcess()

        generation += 1
        let current = generation
        buffer.removeAll()

        let child = Process()
        child.executableURL = config.executable
        child.arguments = config.arguments
        child.currentDirectoryURL = config.workingDirectory
        var environment = config.environment ?? ProcessInfo.processInfo.environment
        // A key in the app's own environment is not passed on; only the Keychain supplies one.
        for name in ["ANTHROPIC_API_KEY", "ANTHROPIC_AUTH_TOKEN"] where config.secrets != nil {
            environment.removeValue(forKey: name)
        }
        for (name, value) in config.secrets?() ?? [:] { environment[name] = value }
        child.environment = environment

        let toChild = Pipe()
        let fromChild = Pipe()
        child.standardInput = toChild
        child.standardOutput = fromChild
        let errors = Pipe()
        child.standardError = errors
        diagnostic = ""
        errors.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            let text = String(decoding: data, as: UTF8.self)
            self?.queue.async {
                guard let self, current == self.generation else { return }
                self.diagnostic = String((self.diagnostic + text).suffix(Self.maxDisplayLength))
            }
        }

        fromChild.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
                return
            }
            self?.queue.async { self?.consume(data, generation: current) }
        }
        child.terminationHandler = { [weak self] _ in
            self?.queue.async { self?.handleExit(generation: current) }
        }

        do {
            try child.run()
        } catch {
            fromChild.fileHandleForReading.readabilityHandler = nil
            errors.fileHandleForReading.readabilityHandler = nil
            for id in resend { finish(id, throwing: BackendError.launchFailed(error.localizedDescription)) }
            throw BackendError.launchFailed(error.localizedDescription)
        }
        // Close this side's copies of the child's pipe ends. Otherwise a write
        // to a backend that has stopped reading would succeed silently
        // instead of failing, and the request would wait for nothing.
        try? toChild.fileHandleForReading.close()
        try? fromChild.fileHandleForWriting.close()
        try? errors.fileHandleForWriting.close()
        process = child
        input = toChild.fileHandleForWriting
        starts += 1
        greeted = false
        queue.asyncAfter(deadline: .now() + config.helloTimeout) { [weak self] in
            guard let self, current == self.generation, !self.greeted else { return }
            // Started but silent. Stop it; the exit handling settles the requests.
            if self.process?.isRunning == true { self.process?.terminate() }
        }
        // Assign the carried-over requests to this process before any write,
        // so a failed write cannot leave them unowned.
        for id in resend { pending[id]?.sent = true }
        try write(.hello(protocolVersion: BackendProtocol.version))
        for id in resend {
            guard let request = pending[id] else { continue }
            try write(.ask(id: id, text: request.text, route: request.route, web: request.web, history: request.history,
                           cloud: request.cloud))
        }
    }

    private func write(_ message: ClientMessage) throws {
        guard let input else { throw BackendError.serviceStopped }
        var line = try ProtocolCodec.encode(message)
        line.append(0x0A)
        try input.write(contentsOf: line)
    }

    private func consume(_ data: Data, generation: Int) {
        guard generation == self.generation else { return }
        buffer.append(data)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer.subdata(in: buffer.startIndex..<newline)
            buffer.removeSubrange(buffer.startIndex...newline)
            guard !line.isEmpty else { continue }
            do {
                handle(try ProtocolCodec.decode(line))
            } catch {
                failAll(BackendError.protocolViolation("unreadable message"))
            }
        }
    }

    private func handle(_ message: ServiceMessage) {
        switch message {
        case .hello(let version, _, _):
            greeted = true
            if version != BackendProtocol.version {
                failAll(BackendError.protocolViolation("backend speaks protocol \(version)"))
            }
        case .answerChunk(let id, let text):
            guard pending[id] != nil else { return }
            pending[id]?.receivedAny = true
            pending[id]?.continuation.yield(.chunk(text))
        case .answerDone(let id, let model, _, let details):
            guard let request = pending.removeValue(forKey: id) else { return }
            request.continuation.yield(.finished(model: model.map { String($0.prefix(Self.maxDisplayLength)) }, details: details))
            request.continuation.finish()
        case .toolRequest(let id, let callID, let tool, let query):
            runTool(requestID: id, callID: callID, tool: tool, query: query)
        case .error(let id, let code, let message):
            let error = BackendError.service(
                code: String(code.prefix(64)),
                message: String(message.prefix(Self.maxDisplayLength))
            )
            if let id {
                finish(id, throwing: error)
            } else {
                // The backend could not tie the problem to a request, so no
                // waiting request can be trusted to finish. End them all
                // rather than leave one waiting forever.
                failAll(error)
            }
        case .bye:
            break
        }
    }

    /// Carries out something the model asked for. The backend only ever asks;
    /// the decision and the action are here, on the app's side.
    private func runTool(requestID: String, callID: String, tool: String, query: String) {
        guard let request = pending[requestID] else { return }  // cancelled meanwhile

        var replied = false
        func reply(ok: Bool, results: [SearchResult], error: String) {
            // One reply per request: whichever of the search and its deadline comes first.
            guard !replied, pending[requestID] != nil else { return }
            replied = true
            do {
                try write(.toolResult(id: requestID, callID: callID, ok: ok, results: results, error: error))
            } catch {
                // The backend never received it, so the model has no results: say so.
                pending[requestID]?.continuation.yield(.searchFailed("the search results could not be passed on"))
                return
            }
            if ok {
                pending[requestID]?.continuation.yield(.sources(results))
            } else {
                pending[requestID]?.continuation.yield(.searchFailed(error))
            }
        }

        // Refuse anything that is not a web search, and any search when the
        // user forbade it for this question, whatever the backend says.
        guard tool == "web_search" else {
            reply(ok: false, results: [], error: "that action is not available")
            return
        }
        guard request.web else {
            reply(ok: false, results: [], error: "web search is turned off for this question")
            return
        }
        guard let webSearch else {
            reply(ok: false, results: [], error: "web search is not set up")
            return
        }

        request.continuation.yield(.searching(query: query))
        let current = generation
        // The backend stops waiting after a while and answers without results.
        // Give up first, so sources are never shown for an answer that did not use them.
        queue.asyncAfter(deadline: .now() + config.searchDeadline) { [weak self] in
            guard let self, current == self.generation else { return }
            reply(ok: false, results: [], error: "the search took too long")
        }
        Task { [weak self] in
            let outcome: Result<[SearchResult], Error>
            do {
                outcome = .success(try await webSearch.search(query))
            } catch {
                outcome = .failure(error)
            }
            self?.queue.async {
                guard let self, current == self.generation else { return }
                switch outcome {
                case .success(let results) where !results.isEmpty:
                    reply(ok: true, results: results, error: "")
                case .success:
                    reply(ok: false, results: [], error: "no results were found")
                case .failure(let error):
                    reply(ok: false, results: [], error: String(error.localizedDescription.prefix(200)))
                }
            }
        }
    }

    private func handleExit(generation: Int) {
        guard generation == self.generation, process != nil else { return }
        for id in reapStoppedProcess() { send(id) }
    }

    /// Clears out a process that has exited and settles the requests it held.
    /// Returns the ids that should be sent again.
    private func reapStoppedProcess() -> [String] {
        process?.terminationHandler = nil
        process = nil
        try? input?.close()
        input = nil
        buffer.removeAll()

        // A request that had not produced anything yet is safe to send again
        // once: this covers the backend going idle just as a question arrives.
        var retry: [String] = []
        for (id, request) in pending where request.sent {
            if !request.receivedAny && !request.retried {
                pending[id]?.retried = true
                pending[id]?.sent = false
                retry.append(id)
            } else {
                finish(id, throwing: BackendError.serviceStopped)
            }
        }
        return retry
    }

    private func finish(_ id: String, throwing error: Error) {
        pending.removeValue(forKey: id)?.continuation.finish(throwing: error)
    }

    private func failAll(_ error: Error) {
        let all = pending
        pending.removeAll()
        for request in all.values { request.continuation.finish(throwing: error) }
    }
}
