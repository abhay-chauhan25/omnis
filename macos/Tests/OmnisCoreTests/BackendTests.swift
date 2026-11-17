import Foundation
import Testing
@testable import OmnisCore

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

        let ask = try json(.ask(id: "q1", text: "line one\nline \"two\" \u{1F600}"))
        #expect(ask["type"] as? String == "ask")
        #expect(ask["id"] as? String == "q1")
        #expect(ask["text"] as? String == "line one\nline \"two\" \u{1F600}")

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
            == .answerDone(id: "q", model: "mock", cancelled: false))
        #expect(try decode(#"{"type":"answer_done","id":"q","cancelled":true}"#)
            == .answerDone(id: "q", model: nil, cancelled: true))
        #expect(try decode(#"{"type":"error","code":"bad_request","message":"m"}"#)
            == .error(id: nil, code: "bad_request", message: "m"))
        #expect(try decode(#"{"type":"error","id":"q","code":"internal","message":"m"}"#)
            == .error(id: "q", code: "internal", message: "m"))
        #expect(try decode(#"{"type":"bye","reason":"idle"}"#) == .bye(reason: "idle"))
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
        #expect(failure(#"{"type":"hello","protocol":true,"service":"s","version":"v"}"#) == .missingField("protocol"))
        #expect(failure(#"{"type":"hello","protocol":"1","service":"s","version":"v"}"#) == .missingField("protocol"))
    }
}

/// These start the real Python service from `backend/`, exactly as the app does.
@Suite(.serialized) struct BackendServiceTests {
    static let backendDirectory = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("backend", isDirectory: true)

    func service(idleSeconds: Double = 0, delayMilliseconds: Int = 1) -> BackendService {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_MOCK_DELAY_MS"] = String(delayMilliseconds)
        return BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", String(idleSeconds)],
            workingDirectory: Self.backendDirectory,
            environment: environment
        ))
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
            case .finished(let name): model = name
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
            == .error(id: nil, code: "unsupported_version", message: "service speaks protocol 1"))
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

    @Test func garbageFromTheBackendIsAnErrorNotACrash() async {
        let backend = fake("echo 'this is not json'; cat > /dev/null")
        await #expect(throws: BackendError.protocolViolation("unreadable message")) {
            _ = try await collect(backend.ask("hello"))
        }
        backend.stop()
    }
}
