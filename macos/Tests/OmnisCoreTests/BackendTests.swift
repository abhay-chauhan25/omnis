import Foundation
import Testing
@testable import OmnisCore

@Suite struct AnswerFormatterTests {
    @Test func linksWrittenByAModelAreNeverClickable() {
        let hostile = [
            "[Apple support](file:///System/Applications/Calculator.app)",
            "[x](https://evil.example/?q=1)",
            "<https://example.com>",
            "see https://example.org/x now",
            "[prefs](x-apple.systempreferences:com.apple.preference.security)",
            "**bold [nested](https://a.example)** and `code`",
        ]
        for text in hostile {
            let formatted = AnswerFormatter.format(text)
            #expect(formatted.runs.allSatisfy { $0.link == nil })
            #expect(!String(formatted.characters).isEmpty)
        }
    }

    @Test func ordinaryFormattingAndLineBreaksSurvive() {
        let formatted = AnswerFormatter.format("**Paris** is the capital.\n\nSecond line.")
        let plain = String(formatted.characters)
        #expect(plain.contains("Paris is the capital."))
        #expect(plain.contains("Second line."))
        #expect(!plain.contains("**"))
        #expect(formatted.runs.contains { $0.inlinePresentationIntent?.contains(.stronglyEmphasized) == true })
        #expect(String(AnswerFormatter.format("").characters) == " ")
    }

    @Test func routePrefixesAreSplitOff() {
        #expect(RoutePrefix.split("local: what is a paper") == AskOptions(route: "local", web: true, text: "what is a paper"))
        #expect(RoutePrefix.split("  Claude:  explain quicksort ") == AskOptions(route: "claude", web: true, text: "explain quicksort"))
        #expect(RoutePrefix.split("Offline: latest news") == AskOptions(route: "local", web: false, text: "latest news"))
        #expect(RoutePrefix.split("what is local: this") == AskOptions(text: "what is local: this"))
        #expect(RoutePrefix.split("local:") == AskOptions(text: "local:"))
        #expect(RoutePrefix.split("offline:   ") == AskOptions(text: "offline:"))
        #expect(RoutePrefix.split("elsewhere: hi") == AskOptions(text: "elsewhere: hi"))
    }
}

@Suite struct ProtocolCodecTests {
    func json(_ message: ClientMessage) throws -> [String: Any] {
        let data = try ProtocolCodec.encode(message)
        #expect(!data.contains(0x0A))
        return try JSONSerialization.jsonObject(with: data) as! [String: Any]
    }

    @Test func encodesEveryClientMessage() throws {
        let hello = try json(.hello(protocolVersion: 1))
        #expect(hello["type"] as? String == "hello")
        #expect(hello["protocol"] as? Int == 1)
        #expect(BackendProtocol.version == 2)

        let ask = try json(.ask(id: "q1", text: "line one\nline \"two\" \u{1F600}"))
        #expect(ask["type"] as? String == "ask")
        #expect(ask["id"] as? String == "q1")
        #expect(ask["text"] as? String == "line one\nline \"two\" \u{1F600}")
        #expect(ask["route"] as? String == "auto")
        #expect(try json(.ask(id: "q", text: "t", route: "local"))["route"] as? String == "local")
        #expect(ask["web"] as? Bool == true)
        #expect(try json(.ask(id: "q", text: "t", web: false))["web"] as? Bool == false)

        let result = try json(.toolResult(id: "q", callID: "c1", ok: true, results: [
            SearchResult(title: "T", url: URL(string: "https://example.com/a?b=1")!, snippet: "S"),
        ], error: ""))
        #expect(result["type"] as? String == "tool_result")
        #expect(result["call_id"] as? String == "c1")
        #expect(result["ok"] as? Bool == true)
        let sent = try #require((result["results"] as? [[String: String]])?.first)
        #expect(sent == ["title": "T", "url": "https://example.com/a?b=1", "snippet": "S"])

        let cancel = try json(.cancel(id: "q1"))
        #expect(cancel["type"] as? String == "cancel")
        #expect(cancel["id"] as? String == "q1")
    }

    @Test func decodesEveryServiceMessage() throws {
        func decode(_ text: String) throws -> ServiceMessage { try ProtocolCodec.decode(Data(text.utf8)) }
        #expect(try decode(#"{"type":"hello","protocol":1,"service":"omnis-backend","version":"0.1.0"}"#)
            == .hello(protocolVersion: 1, service: "omnis-backend", version: "0.1.0"))
        #expect(try decode(#"{"type":"answer_chunk","id":"q","text":"hi "}"#) == .answerChunk(id: "q", text: "hi "))
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"mock","cancelled":false}"#)
            == .answerDone(id: "q", model: "mock", cancelled: false, details: AnswerDetails()))
        #expect(try decode(#"{"type":"answer_done","id":"q","cancelled":true}"#)
            == .answerDone(id: "q", model: nil, cancelled: true, details: AnswerDetails()))
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"qwen3:4b","cancelled":false,"route":"local","reason":"short","input_tokens":12,"output_tokens":34,"load_ms":2000,"total_ms":4100,"cost_usd":0.0}"#)
            == .answerDone(id: "q", model: "qwen3:4b", cancelled: false, details: AnswerDetails(
                route: "local", reason: "short", inputTokens: 12, outputTokens: 34,
                loadMilliseconds: 2000, totalMilliseconds: 4100, costUSD: 0)))
        // Wrongly typed extras are ignored, not trusted.
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"m","route":7,"input_tokens":"lots","cost_usd":true}"#)
            == .answerDone(id: "q", model: "m", cancelled: false, details: AnswerDetails()))
        #expect(try decode(#"{"type":"error","code":"bad_request","message":"m"}"#)
            == .error(id: nil, code: "bad_request", message: "m"))
        #expect(try decode(#"{"type":"error","id":"q","code":"internal","message":"m"}"#)
            == .error(id: "q", code: "internal", message: "m"))
        #expect(try decode(#"{"type":"bye","reason":"idle"}"#) == .bye(reason: "idle"))
        #expect(try decode(#"{"type":"tool_request","id":"q","call_id":"c","tool":"web_search","query":"max plan"}"#)
            == .toolRequest(id: "q", callID: "c", tool: "web_search", query: "max plan"))
    }

    @Test func refusesMalformedServiceMessages() {
        func failure(_ text: String) -> ProtocolCodecError? {
            do { _ = try ProtocolCodec.decode(Data(text.utf8)); return nil } catch { return error as? ProtocolCodecError }
        }
        #expect(failure("nonsense") == .notJSONObject)
        #expect(failure("[1]") == .notJSONObject)
        #expect(failure(#"{"type":"run_command","cmd":"ls"}"#) == .unknownType("run_command"))
        #expect(failure(#"{"id":"q"}"#) == .missingField("type"))
        #expect(failure(#"{"type":"answer_chunk","id":"q"}"#) == .missingField("text"))
        #expect(failure(#"{"type":"tool_request","id":"q","tool":"web_search","query":"x"}"#) == .missingField("call_id"))
        #expect(failure(#"{"type":"tool_request","id":"q","call_id":"c","tool":"web_search","query":7}"#) == .missingField("query"))
        #expect(failure(#"{"type":"hello","protocol":true,"service":"s","version":"v"}"#) == .missingField("protocol"))
        #expect(failure(#"{"type":"hello","protocol":"1","service":"s","version":"v"}"#) == .missingField("protocol"))
    }
}

/// These start the real Python service from `backend/`, exactly as the app does.
@Suite(.serialized) struct BackendServiceTests {
    static let backendDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("backend", isDirectory: true)

    func service(idleSeconds: Double = 0, delayMilliseconds: Int = 1, webSearch: (any WebSearching)? = nil) -> BackendService {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_MOCK_DELAY_MS"] = String(delayMilliseconds)
        return BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", String(idleSeconds)],
            workingDirectory: Self.backendDirectory,
            environment: environment
        ), webSearch: webSearch)
    }

    /// Runs a question and returns the text plus every non-text event.
    func trace(_ stream: AsyncThrowingStream<AnswerEvent, Error>) async throws -> (text: String, events: [AnswerEvent]) {
        var text = ""
        var events: [AnswerEvent] = []
        for try await event in stream {
            if case .chunk(let piece) = event { text += piece } else { events.append(event) }
        }
        return (text, events)
    }

    // The mock backend asks for a web search when a question starts with "search:".

    @Test func aSearchRequestIsCarriedOutByTheAppAndTheResultsGoBack() async throws {
        let stub = StubSearch()
        let backend = service(webSearch: stub)
        let run = try await trace(backend.ask("search: claude max plan"))
        #expect(stub.queries == ["claude max plan"])
        #expect(run.events.prefix(2) == [.searching(query: "claude max plan"), .sources(stub.results)])
        #expect(run.text == "Search ok=True results=2 first=What is the Max plan? error=")
        backend.stop()
    }

    @Test func offlineQuestionsAreNeverSearchedEvenIfTheBackendAsks() async throws {
        let stub = StubSearch()
        let backend = service(webSearch: stub)
        let run = try await trace(backend.ask("search: latest news", web: false))
        #expect(stub.queries.isEmpty)
        #expect(run.events.first == .searchFailed("web search is turned off for this question"))
        #expect(run.text.contains("ok=False results=0"))
        backend.stop()
    }

    @Test func withoutASearcherTheModelIsToldSearchIsNotSetUp() async throws {
        let backend = service()
        let run = try await trace(backend.ask("search: anything"))
        #expect(run.events.first == .searchFailed("web search is not set up"))
        #expect(run.text.contains("error=web search is not set up"))
        backend.stop()
    }

    @Test func aFailedOrEmptySearchIsReportedNotHidden() async throws {
        let stub = StubSearch()
        stub.failure = WebSearchError.dockerNotRunning
        let backend = service(webSearch: stub)
        let failed = try await trace(backend.ask("search: x"))
        #expect(failed.events.contains(.searchFailed("Docker is not running, so web search is unavailable")))
        #expect(failed.text.contains("ok=False"))

        stub.failure = nil
        stub.results = []
        let empty = try await trace(backend.ask("search: y"))
        #expect(empty.events.contains(.searchFailed("no results were found")))
        backend.stop()
    }

    @Test func cancellingDuringASearchLeavesTheServiceUsable() async throws {
        let stub = StubSearch()
        stub.delay = 2
        let backend = service(webSearch: stub)
        let task = Task { try await self.trace(backend.ask("search: slow")) }
        #expect(await waitUntil { !stub.queries.isEmpty })
        task.cancel()
        _ = try? await task.value
        stub.delay = 0
        let next = try await trace(backend.ask("search: fast"))
        #expect(next.text.contains("ok=True"))
        #expect(backend.startCount == 1)
        backend.stop()
    }

    /// A backend that asks for something other than a web search. The app
    /// must refuse, whatever the request says.
    @Test func anythingOtherThanAWebSearchIsRefused() async throws {
        let script = #"""
        echo '{"type":"hello","protocol":2,"service":"fake","version":"0"}'
        while read -r line; do
          case "$line" in
            *'"type":"ask"'*)
              id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
              echo "{\"type\":\"tool_request\",\"id\":\"$id\",\"call_id\":\"c1\",\"tool\":\"run_shell\",\"query\":\"rm -rf ~\"}" ;;
            *'"type":"tool_result"'*)
              case "$line" in *'"ok":false'*) verdict=refused ;; *) verdict=ALLOWED ;; esac
              echo "{\"type\":\"answer_chunk\",\"id\":\"$id\",\"text\":\"$verdict\"}"
              echo "{\"type\":\"answer_done\",\"id\":\"$id\",\"model\":\"fake\",\"cancelled\":false}" ;;
          esac
        done
        """#
        let stub = StubSearch()
        let backend = BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        ), webSearch: stub)
        let run = try await trace(backend.ask("do something"))
        #expect(run.text == "refused")
        #expect(stub.queries.isEmpty)
        #expect(run.events.first == .searchFailed("that action is not available"))
        backend.stop()
    }

    func fake(_ script: String, helloTimeout: TimeInterval = 10) -> BackendService {
        BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            helloTimeout: helloTimeout
        ))
    }

    func collect(_ stream: AsyncThrowingStream<AnswerEvent, Error>) async throws -> (text: String, model: String?, chunks: Int) {
        var text = ""
        var model: String?
        var chunks = 0
        for try await event in stream {
            switch event {
            case .chunk(let piece): text += piece; chunks += 1
            case .finished(let name, _): model = name
            case .searching, .sources, .searchFailed: break
            }
        }
        return (text, model, chunks)
    }

    @Test func nothingRunsUntilTheFirstQuestion() async throws {
        let backend = service()
        #expect(!backend.isRunning)
        #expect(backend.startCount == 0)

        let answer = try await collect(backend.ask("what is OMNIS?"))
        #expect(answer.text.contains("mock answer"))
        #expect(answer.text.contains("what is OMNIS?"))
        #expect(answer.model == "mock")
        #expect(answer.chunks > 5)
        #expect(backend.isRunning)
        #expect(backend.startCount == 1)

        // A second question reuses the same process.
        _ = try await collect(backend.ask("again"))
        #expect(backend.startCount == 1)

        backend.stop()
        #expect(!backend.isRunning)
    }

    @Test func stopsWhenIdleAndStartsAgainOnDemand() async throws {
        let backend = service(idleSeconds: 0.4)
        _ = try await collect(backend.ask("first"))
        #expect(await waitUntil { !backend.isRunning })
        let answer = try await collect(backend.ask("second"))
        #expect(answer.text.contains("second"))
        #expect(backend.startCount == 2)
        backend.stop()
    }

    @Test func cancellingStopsTheAnswerAndLeavesTheServiceUsable() async throws {
        let backend = service(delayMilliseconds: 40)
        let task = Task { () -> Int in
            var seen = 0
            for try await event in backend.ask("a long question") {
                if case .chunk = event { seen += 1 }
            }
            return seen
        }
        try await Task.sleep(nanoseconds: 250_000_000)
        task.cancel()
        let seen = (try? await task.value) ?? 0
        #expect(seen < 20)

        let answer = try await collect(backend.ask("after cancel"))
        #expect(answer.text.contains("after cancel"))
        #expect(backend.startCount == 1)
        backend.stop()
    }

    @Test func aCrashMidAnswerIsAnErrorAndTheNextQuestionRecovers() async throws {
        let backend = service(delayMilliseconds: 40)
        var chunks = 0
        var caught: Error?
        do {
            for try await event in backend.ask("this will be interrupted") {
                if case .chunk = event {
                    chunks += 1
                    if chunks == 1, let pid = backend.processIdentifier { kill(pid, SIGKILL) }
                }
            }
        } catch {
            caught = error
        }
        #expect(caught as? BackendError == .serviceStopped)

        let answer = try await collect(backend.ask("recovered"))
        #expect(answer.text.contains("recovered"))
        #expect(backend.startCount == 2)
        backend.stop()
    }

    @Test func aBackendThatCannotStartIsReported() async {
        let backend = BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/definitely/not/python"),
            arguments: [],
            workingDirectory: URL(fileURLWithPath: "/tmp")
        ))
        do {
            _ = try await collect(backend.ask("hello"))
            Issue.record("expected a failure")
        } catch let error as BackendError {
            guard case .launchFailed = error else { Issue.record("wrong error: \(error)"); return }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func aBackendThatDiesAtOnceIsRetriedOnceThenReported() async {
        let backend = fake("exit 1")
        await #expect(throws: BackendError.serviceStopped) {
            _ = try await collect(backend.ask("hello"))
        }
        #expect(backend.startCount == 2)
    }

    /// The backend starts but never answers. The request must end with an
    /// error once the hello deadline passes, not wait for the process.
    @Test(.timeLimit(.minutes(1))) func aBackendThatStartsButStaysSilentIsStopped() async {
        let backend = fake("exec 0<&-; exec sleep 20", helloTimeout: 0.5)
        let started = Date()
        await #expect(throws: BackendError.serviceStopped) {
            _ = try await collect(backend.ask("hello"))
        }
        // It fails at the hello deadline (twice: one retry), not when the sleep ends.
        #expect(Date().timeIntervalSince(started) < 10)
        #expect(backend.startCount == 2)
        #expect(await waitUntil { !backend.isRunning })
    }

    @Test func aVersionMismatchIsReportedCleanly() async {
        let backend = fake(#"echo '{"type":"hello","protocol":99,"service":"x","version":"0"}'; cat > /dev/null"#)
        await #expect(throws: BackendError.protocolViolation("backend speaks protocol 99")) {
            _ = try await collect(backend.ask("hello"))
        }
        backend.stop()
    }

    @Test func theRealServiceRefusesAnotherProtocolVersion() async throws {
        // Speak to the real service by hand with the wrong version.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", "-m", "omnis_backend"]
        process.currentDirectoryURL = Self.backendDirectory
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        try input.fileHandleForWriting.write(contentsOf: Data(#"{"type":"hello","protocol":99}"#.utf8) + Data([0x0A]))
        let reply = try output.fileHandleForReading.readToEnd() ?? Data()
        process.waitUntilExit()
        #expect(try ProtocolCodec.decode(reply.split(separator: 0x0A).first.map { Data($0) } ?? Data())
            == .error(id: nil, code: "unsupported_version", message: "service speaks protocol 2"))
        #expect(process.terminationStatus == 2)
    }

    @Test func anOverlongQuestionIsRefusedWithoutStartingTheBackend() async {
        let backend = service()
        let huge = String(repeating: "x", count: BackendService.maxQuestionLength + 1)
        await #expect(throws: BackendError.questionTooLong) {
            _ = try await collect(backend.ask(huge))
        }
        #expect(backend.startCount == 0)
    }

    @Test func theLongestAllowedQuestionStillWorks() async throws {
        let backend = service(delayMilliseconds: 0)
        let big = String(repeating: "\u{1}", count: BackendService.maxQuestionLength)
        let answer = try await collect(backend.ask(big))
        #expect(answer.model == "mock")
        backend.stop()
    }

    @Test func anErrorWithNoRequestIdEndsTheWaitInsteadOfHanging() async {
        let backend = fake(#"echo '{"type":"error","code":"bad_request","message":"message line is too long"}'; cat > /dev/null"#)
        await #expect(throws: BackendError.service(code: "bad_request", message: "message line is too long")) {
            _ = try await collect(backend.ask("hello"))
        }
        backend.stop()
    }

    @Test func aFailedStartLeavesADiagnostic() async {
        let backend = fake("echo 'ModuleNotFoundError: omnis_backend' >&2; exit 1")
        await #expect(throws: BackendError.serviceStopped) {
            _ = try await collect(backend.ask("hello"))
        }
        #expect(await waitUntil { backend.lastDiagnostic?.contains("ModuleNotFoundError") == true })
    }

    @Test func manyQuestionsAcrossARestartAllFinish() async throws {
        let backend = service(idleSeconds: 0.3)
        for round in 0..<3 {
            try await withThrowingTaskGroup(of: String.self) { group in
                for index in 0..<5 {
                    group.addTask { try await self.collect(backend.ask("round \(round) item \(index)")).text }
                }
                var finished = 0
                for try await text in group { #expect(text.contains("round \(round)")); finished += 1 }
                #expect(finished == 5)
            }
            #expect(await waitUntil { !backend.isRunning })
        }
        #expect(backend.startCount == 3)
    }

    /// Uses the real models. Slow, so it only runs when asked:
    ///   OMNIS_LIVE_TESTS=1 swift test --filter live
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveLocalModelAnswersThroughTheWholeChain() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let backend = BackendService(config: config)

        var text = ""
        var finished: (model: String?, details: AnswerDetails)?
        for try await event in backend.ask("What is the capital of France? Answer in one short sentence.") {
            switch event {
            case .chunk(let piece): text += piece
            case .finished(let model, let details): finished = (model, details)
            case .searching, .sources, .searchFailed: break
            }
        }
        #expect(text.contains("Paris"))
        #expect(!text.contains("</think>"))
        #expect(finished?.model == "gemma4:12b")
        #expect(finished?.details.route == "local")
        #expect((finished?.details.outputTokens ?? 0) > 0)

        var standIn: AnswerDetails?
        for try await event in backend.ask("use claude to explain quicksort") {
            if case .finished(_, let details) = event { standIn = details }
        }
        #expect(standIn?.route == "cloud-mock")
        #expect(standIn?.costUSD == 0)

        // A typed route survives the trip: a Claude-sounding request stays local.
        var forced: AnswerDetails?
        for try await event in backend.ask("use claude to say hello in one word", route: "local") {
            if case .finished(_, let details) = event { forced = details }
        }
        #expect(forced?.route == "local")
        backend.stop()
    }

    /// Real model, real search container, real web. Needs Docker running.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveWebSearch
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveWebSearchAnswersFromRealResults() async throws {
        let environment = ProcessInfo.processInfo.environment
        let ollama = URL(fileURLWithPath: environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        let docker = URL(fileURLWithPath: environment["OMNIS_DOCKER"] ?? "/usr/local/bin/docker")
        let container = SearXNGContainer(docker: docker,
                                         settingsDirectory: OmnisPaths.supportDirectory.appendingPathComponent("searxng"))
        let search = SearXNGSearch(container: container, idleSeconds: 0)
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let backend = BackendService(config: config, webSearch: search)

        let started = Date()
        let run = try await trace(backend.ask("What are the benefits of the Claude Max plan?"))
        print("LIVE_SEARCH seconds \(Date().timeIntervalSince(started)) text: \(run.text)")

        let sources = run.events.compactMap { event -> [SearchResult]? in
            if case .sources(let results) = event { return results } else { return nil }
        }.first ?? []
        #expect(!sources.isEmpty)
        #expect(sources.allSatisfy { $0.url.scheme == "https" })
        #expect(run.text.localizedCaseInsensitiveContains("max"))
        let details = run.events.compactMap { event -> AnswerDetails? in
            if case .finished(_, let details) = event { return details } else { return nil }
        }.first
        #expect((details?.searches ?? 0) >= 1)

        // The same question offline must not search.
        let offline = try await trace(backend.ask("What are the benefits of the Claude Max plan?", web: false))
        #expect(!offline.events.contains { if case .searching = $0 { return true } else { return false } })

        backend.stop()
        await search.shutdown()
    }

    @Test func garbageFromTheBackendIsAnErrorNotACrash() async {
        let backend = fake("echo 'this is not json'; cat > /dev/null")
        await #expect(throws: BackendError.protocolViolation("unreadable message")) {
            _ = try await collect(backend.ask("hello"))
        }
        backend.stop()
    }
}

/// A search provider for tests: no Docker, no network.
final class StubSearch: WebSearching, @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [String] = []
    var results = [
        SearchResult(title: "What is the Max plan?", url: URL(string: "https://support.example/max")!, snippet: "More usage."),
        SearchResult(title: "Pricing", url: URL(string: "https://example.com/pricing")!, snippet: "Free, Pro, Max."),
    ]
    var failure: Error?
    var delay: Double = 0

    var queries: [String] { lock.withLock { asked } }

    func search(_ query: String) async throws -> [SearchResult] {
        lock.withLock { asked.append(query) }
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        if let failure { throw failure }
        return results
    }

    func shutdown() async {}
}
