import CoreGraphics
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
        #expect((ask["history"] as? [Any])?.isEmpty == true)
        let cloud = try #require(ask["cloud"] as? [String: Any])
        #expect(cloud["allowed"] as? Bool == true)
        #expect(cloud["max_usd"] as? Double == 1.0)
        let denied = try json(.ask(id: "q", text: "t", cloud: CloudPermission(allowed: false, maxUSD: 0, reason: "budget used up")))
        #expect((denied["cloud"] as? [String: Any])?["allowed"] as? Bool == false)
        #expect((denied["cloud"] as? [String: Any])?["reason"] as? String == "budget used up")
        let withHistory = try json(.ask(id: "q", text: "next", history: [
            ChatTurn(role: .user, content: "first"), ChatTurn(role: .assistant, content: "reply"),
        ]))
        #expect(withHistory["history"] as? [[String: String]] == [
            ["role": "user", "content": "first"], ["role": "assistant", "content": "reply"],
        ])

        let result = try json(.toolResult(id: "q", callID: "c1", ok: true, results: [
            SearchResult(title: "T", url: URL(string: "https://example.com/a?b=1")!, snippet: "S"),
        ], error: ""))
        #expect(result["type"] as? String == "tool_result")
        #expect(result["call_id"] as? String == "c1")
        #expect(result["ok"] as? Bool == true)
        let sent = try #require((result["results"] as? [[String: String]])?.first)
        #expect(sent == ["title": "T", "url": "https://example.com/a?b=1", "snippet": "S"])

        let calendarAsk = try json(.ask(id: "q", text: "t", personal: true, calendar: true))
        #expect(calendarAsk["personal"] as? Bool == true)
        #expect(calendarAsk["calendar"] as? Bool == true)
        #expect(calendarAsk["calendar_write"] as? Bool == false)
        #expect(calendarAsk["calendar_delete"] as? String == "none")
        #expect(try json(.ask(id: "q", text: "t", calendarWrite: true, calendarDelete: .events))["calendar_delete"] as? String == "events")
        #expect(try json(.ask(id: "q", text: "t", calendarWrite: true))["calendar_write"] as? Bool == true)
        #expect(ask["personal"] as? Bool == false)
        #expect(ask["calendar"] as? Bool == false)
        let calendarResult = try json(.toolResult(id: "q", callID: "c", ok: true, results: [], error: "", content: "Wed 18 Nov: Standup"))
        #expect(calendarResult["content"] as? String == "Wed 18 Nov: Standup")

        let configure = try json(.configure(claudeKey: "sk-test"))
        #expect(configure["type"] as? String == "configure")
        #expect(configure["claude_key"] as? String == "sk-test")

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
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"gemma4:12b","route":"local","fallback":"Claude could not be used (there is no Claude API credit)"}"#)
            == .answerDone(id: "q", model: "gemma4:12b", cancelled: false, details: AnswerDetails(
                route: "local", fallback: "Claude could not be used (there is no Claude API credit)")))
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"m","fallback":""}"#)
            == .answerDone(id: "q", model: "m", cancelled: false, details: AnswerDetails()))
        // Wrongly typed extras are ignored, not trusted.
        #expect(try decode(#"{"type":"answer_done","id":"q","model":"m","route":7,"input_tokens":"lots","cost_usd":true}"#)
            == .answerDone(id: "q", model: "m", cancelled: false, details: AnswerDetails()))
        #expect(try decode(#"{"type":"error","code":"bad_request","message":"m"}"#)
            == .error(id: nil, code: "bad_request", message: "m"))
        #expect(try decode(#"{"type":"error","id":"q","code":"internal","message":"m"}"#)
            == .error(id: "q", code: "internal", message: "m"))
        #expect(try decode(#"{"type":"bye","reason":"idle"}"#) == .bye(reason: "idle"))
        #expect(try decode(#"{"type":"tool_request","id":"q","call_id":"c","tool":"calendar_events","query":"","arguments":{"start":"2026-11-18","end":"2026-11-19","junk":7}}"#)
            == .toolRequest(id: "q", callID: "c", tool: "calendar_events", query: "",
                            arguments: ["start": "2026-11-18", "end": "2026-11-19"]))
        #expect(try decode(#"{"type":"usage","id":"q","model":"claude-haiku-5-5","input_tokens":900,"output_tokens":40,"cost_usd":0.00011}"#)
            == .usage(id: "q", model: "claude-haiku-5-5", inputTokens: 900, outputTokens: 40, costUSD: 0.00011))
        // Negative or absurd figures cannot reduce what is recorded.
        #expect(try decode(#"{"type":"usage","id":"q","model":"m","input_tokens":-5,"output_tokens":3,"cost_usd":-2}"#)
            == .usage(id: "q", model: "m", inputTokens: 0, outputTokens: 3, costUSD: 0))
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

    /// The backend with a stand-in for Claude (no network, no key, no model).
    func cloudService() -> BackendService {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_CLAUDE"] = "mock"
        var config = BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", "0", "--engine", "local"],
            workingDirectory: Self.backendDirectory, environment: environment
        )
        return BackendService(config: config, webSearch: StubSearch())
    }

    @Test func aPublicQuestionGoesToClaudeAndComesBackWithItsCost() async throws {
        let backend = cloudService()
        let run = try await trace(backend.ask("who won the world cup"))
        #expect(run.text == "Mock Claude reply. No API call was made. You asked: who won the world cup")
        let details = try #require(run.events.compactMap { event -> (String?, AnswerDetails)? in
            if case .finished(let model, let details) = event { return (model, details) } else { return nil }
        }.first)
        #expect(details.0 == "claude-haiku-5-5")
        #expect(details.1.route == "cloud")
        #expect((details.1.costUSD ?? 0) > 0)
        #expect(details.1.fallback == nil)
        // The cost also arrives as its own event, as soon as the turn is billed.
        let billed = run.events.compactMap { event -> Double? in
            if case .usage(let model, _, _, let cost) = event, model == "claude-haiku-5-5" { return cost } else { return nil }
        }
        #expect(billed.count == 1)
        #expect(abs((billed.first ?? 0) - (details.1.costUSD ?? -1)) < 1e-6)
        backend.stop()
    }

    @Test func claudeSearchesThroughTheAppToo() async throws {
        let stub = StubSearch()
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_CLAUDE"] = "mock"
        let backend = BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", "0", "--engine", "local"],
            workingDirectory: Self.backendDirectory, environment: environment
        ), webSearch: stub)
        let run = try await trace(backend.ask("search: latest news"))
        #expect(stub.queries == ["latest news"])
        #expect(run.events.contains(.sources(stub.results)))
        #expect(run.text.hasPrefix("Mock Claude reply written from the search results."))
        // Turning web off is enforced by the app whatever the backend asks for.
        let off = try await trace(backend.ask("search: latest news", web: false))
        #expect(stub.queries.count == 1)
        #expect(!off.events.contains { if case .sources = $0 { return true } else { return false } })
        backend.stop()
    }

    /// The key reaches the backend as a message over the pipe, never through
    /// the environment, where other programs could read it.
    @Test(.timeLimit(.minutes(1))) func theClaudeKeyIsHandedOverInAMessageNotTheEnvironment() async throws {
        let script = #"""
        echo '{"type":"hello","protocol":2,"service":"fake","version":"0"}'
        got=none
        while read -r line; do
          case "$line" in
            *'"type":"configure"'*)
              case "$line" in *'from-the-keychain'*) got=key ;; *) got=other ;; esac ;;
            *'"type":"ask"'*)
              id=$(printf '%s' "$line" | sed -n 's/.*"id":"\([^"]*\)".*/\1/p')
              leaked=$(env | grep -c '^ANTHROPIC_')
              echo "{\"type\":\"answer_chunk\",\"id\":\"$id\",\"text\":\"configure=$got anthropic_env_vars=$leaked\"}"
              echo "{\"type\":\"answer_done\",\"id\":\"$id\",\"model\":\"fake\",\"cancelled\":false}" ;;
          esac
        done
        """#
        func backend(key: (@Sendable () -> String?)?) -> BackendService {
            var config = BackendConfig(
                executable: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
                workingDirectory: URL(fileURLWithPath: "/tmp"),
                environment: ["PATH": "/usr/bin:/bin", "ANTHROPIC_API_KEY": "from-the-app-environment",
                              "ANTHROPIC_AUTH_TOKEN": "stray-token", "ANTHROPIC_BASE_URL": "https://elsewhere.example",
                              "ANTHROPIC_LOG": "debug"]
            )
            config.claudeKey = key
            return BackendService(config: config)
        }
        let withKey = backend(key: { "from-the-keychain" })
        #expect(try await trace(withKey.ask("x")).text == "configure=key anthropic_env_vars=0")
        withKey.stop()

        // No key saved: no configure message, and still nothing inherited.
        let noKey = backend(key: { nil })
        #expect(try await trace(noKey.ask("x")).text == "configure=none anthropic_env_vars=0")
        noKey.stop()

        // Even a setup with no key provider at all inherits nothing.
        let bare = backend(key: nil)
        #expect(try await trace(bare.ask("x")).text == "configure=none anthropic_env_vars=0")
        bare.stop()
    }

    // The mock backend asks for the calendar when a question starts with "calendar:".

    func calendarService(_ calendar: (any CalendarReading)?) -> BackendService {
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_MOCK_DELAY_MS"] = "1"
        return BackendService(config: BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", "0"],
            workingDirectory: Self.backendDirectory, environment: environment
        ), calendar: calendar)
    }

    @Test func theCalendarIsReadByTheAppForTheDaysAskedFor() async throws {
        let stub = StubCalendar()
        stub.events = [CalendarEvent(title: "Standup", start: Date(timeIntervalSince1970: 1_795_000_000),
                                     end: Date(timeIntervalSince1970: 1_795_001_800), calendar: "Work")]
        let backend = calendarService(stub)
        let run = try await trace(backend.ask("calendar: 2026-11-18 2026-11-19", calendar: true))
        let expected = try CalendarFormatter.range(start: "2026-11-18", end: "2026-11-19")
        #expect(stub.ranges.count == 1)
        #expect(stub.ranges.first?.0 == expected.0)
        #expect(stub.ranges.first?.1 == expected.1)
        #expect(run.events.prefix(2) == [.readingCalendar, .calendarRead(summary: "18 Nov to 19 Nov", events: 1)])
        #expect(run.text.hasPrefix("Calendar ok=True error= content="))
        #expect(run.text.contains("Standup (Work)"))
        backend.stop()
    }

    // The mock backend proposes an event when a question starts with "event:".

    @Test func aProposedEventIsCheckedAndHandedOverAsAPreviewOnly() async throws {
        let stub = StubCalendar()
        let backend = calendarService(stub)
        let run = try await trace(backend.ask("event: Lunch with Sam | 2026-11-18T13:00 | 2026-11-18T14:00",
                                              calendar: true, calendarWrite: true, deletes: .all))
        let expected = try EventDraft.parse(["title": "Lunch with Sam", "start": "2026-11-18T13:00",
                                             "end": "2026-11-18T14:00", "all_day": "false"])
        #expect(run.events.first == .changeProposed(.create(expected)))
        #expect(run.text == "Event ok=True error=")
        #expect(stub.ranges.isEmpty)        // proposing reads nothing
        backend.stop()
    }

    @Test func anEventIsRefusedUnlessTheAppOfferedThatAndItsDetailsAreValid() async throws {
        let backend = calendarService(StubCalendar())
        let notOffered = try await trace(backend.ask("event: Lunch | 2026-11-18T13:00 | 2026-11-18T14:00", calendar: true))
        #expect(notOffered.events.first == .eventRefused("changing the calendar is not available"))
        #expect(notOffered.text.hasPrefix("Event ok=False"))

        let bad = try await trace(backend.ask("event: Lunch | tomorrow | later", calendar: true, calendarWrite: true, deletes: .all))
        #expect(bad.events.first == .eventRefused("the event could not be prepared: its date or time was not valid"))
        let backwards = try await trace(backend.ask("event: Lunch | 2026-11-18T13:00 | 2026-11-18T12:00",
                                                    calendar: true, calendarWrite: true, deletes: .all))
        #expect(backwards.events.first == .eventRefused("the event could not be prepared: it ends before it starts"))
        backend.stop()
    }

    // The mock backend passes "tool: NAME key=value; key=value" straight to the app.

    func stubWithTwoEvents() -> StubCalendar {
        let stub = StubCalendar()
        stub.events = [
            CalendarEvent(title: "Standup", start: Zone.date("2026-11-18T14:00:00Z"), end: Zone.date("2026-11-18T14:30:00Z"),
                          calendar: "Work", key: "abc|1", repeats: true),
            CalendarEvent(title: "Dentist", start: Zone.date("2026-11-18T15:00:00Z"), end: Zone.date("2026-11-18T16:00:00Z"),
                          calendar: "Home", location: "Main Street Dental", key: "def|2"),
        ]
        return stub
    }

    func changes(_ run: (text: String, events: [AnswerEvent])) -> [CalendarChange] {
        run.events.compactMap { if case .changeProposed(let change) = $0 { return change } else { return nil } }
    }

    func refusals(_ run: (text: String, events: [AnswerEvent])) -> [String] {
        run.events.compactMap { if case .eventRefused(let why) = $0 { return why } else { return nil } }
    }

    @Test func anEventIsChangedOrDeletedByTheIdItWasListedWith() async throws {
        let stub = stubWithTwoEvents()
        let backend = calendarService(stub)
        // An id means nothing until the calendar has been read.
        let early = try await trace(backend.ask("tool: calendar_delete_event event=e2", calendar: true, calendarWrite: true, deletes: .all))
        #expect(refusals(early).first?.hasPrefix("that event id is not known") == true)

        let read = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        #expect(read.text.contains("[e1] ") && read.text.contains("[e2] "))
        #expect(!read.text.contains("abc|1"))

        let dentist = try await stub.snapshot(key: "def|2")
        let moved = try await trace(backend.ask("tool: calendar_update_event event=e2; start=2026-11-18T15:00; scope=future",
                                                calendar: true, calendarWrite: true, deletes: .all))
        let after = try dentist.draft.applying(["start": "2026-11-18T15:00"])
        // "future" means nothing for an event that does not repeat.
        #expect(changes(moved) == [.update(original: dentist, after: after, future: false)])
        #expect(moved.text == "Tool ok=True error= content=")       // the model learns only that a preview was shown

        let standup = try await stub.snapshot(key: "abc|1")
        let deleted = try await trace(backend.ask("tool: calendar_delete_event event=e1; scope=future",
                                                  calendar: true, calendarWrite: true, deletes: .all))
        #expect(changes(deleted) == [.delete(standup, future: true)])

        let nothing = try await trace(backend.ask("tool: calendar_update_event event=e2; title=Dentist",
                                                  calendar: true, calendarWrite: true, deletes: .all))
        #expect(refusals(nothing) == ["that would not change anything about the event"])
        let unknown = try await trace(backend.ask("tool: calendar_delete_event event=e77", calendar: true, calendarWrite: true, deletes: .all))
        #expect(changes(unknown).isEmpty && refusals(unknown).count == 1)
        // The event has gone by the time it is looked up.
        stub.events.removeAll { $0.key == "def|2" }
        let gone = try await trace(backend.ask("tool: calendar_delete_event event=e2", calendar: true, calendarWrite: true, deletes: .all))
        #expect(refusals(gone).first?.hasPrefix("that event has changed or no longer exists") == true)
        backend.stop()
    }

    @Test func noChangeToolWorksUnlessTheAppOfferedChangesForThatQuestion() async throws {
        let stub = stubWithTwoEvents()
        let backend = calendarService(stub)
        _ = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        for request in ["calendar_update_event event=e2; title=X", "calendar_delete_event event=e2",
                        "calendar_create_calendar name=Gym", "calendar_rename_calendar name=Work; new_name=Office",
                        "calendar_delete_calendar name=Work", "calendar_wipe_everything name=Work"] {
            let run = try await trace(backend.ask("tool: \(request)", calendar: true, calendarWrite: false))
            #expect(changes(run).isEmpty, "\(request)")
            #expect(run.text.hasPrefix("Tool ok=False"), "\(request)")
        }
        let unknown = try await trace(backend.ask("tool: calendar_wipe_everything name=Work", calendar: true, calendarWrite: true, deletes: .all))
        #expect(changes(unknown).isEmpty && unknown.text.hasPrefix("Tool ok=False"))
        backend.stop()
    }

    @Test func deletingIsRefusedBeyondWhatTheAppAllowedForThatQuestion() async throws {
        let stub = stubWithTwoEvents()
        let backend = calendarService(stub)
        _ = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        let why = "deleting was not asked for in the user's message. Ask them to say plainly what to delete"
        let noDelete = try await trace(backend.ask("tool: calendar_delete_event event=e2", calendar: true, calendarWrite: true))
        #expect(changes(noDelete).isEmpty && refusals(noDelete) == [why])
        let eventsOnly = try await trace(backend.ask("tool: calendar_delete_calendar name=Work", calendar: true,
                                                     calendarWrite: true, deletes: .events))
        #expect(changes(eventsOnly).isEmpty && refusals(eventsOnly) == [why])
        let allowed = try await trace(backend.ask("tool: calendar_delete_event event=e2", calendar: true,
                                                  calendarWrite: true, deletes: .events))
        #expect(changes(allowed).count == 1)
        // Other changes are unaffected.
        let update = try await trace(backend.ask("tool: calendar_update_event event=e2; title=Checkup", calendar: true, calendarWrite: true))
        #expect(changes(update).count == 1)
        backend.stop()
    }

    @Test func aCalendarDeletionPreviewSaysWhichAccountAndHowMuchWouldGo() async throws {
        let stub = stubWithTwoEvents()
        stub.list = [CalendarInfo(name: "Home", isDefault: true, account: "iCloud"), CalendarInfo(name: "Work", account: "Google")]
        stub.counts = ["Work": 37]
        let backend = calendarService(stub)
        let run = try await trace(backend.ask("tool: calendar_delete_calendar name=work", calendar: true, calendarWrite: true, deletes: .all))
        #expect(changes(run) == [.deleteCalendar(name: "Work", account: "Google", events: 37, isDefault: false)])
        let home = try await trace(backend.ask("tool: calendar_delete_calendar name=Home", calendar: true, calendarWrite: true, deletes: .all))
        #expect(changes(home) == [.deleteCalendar(name: "Home", account: "iCloud", events: nil, isDefault: true)])
        let made = try await trace(backend.ask("tool: calendar_create_calendar name=Gym", calendar: true, calendarWrite: true))
        #expect(changes(made) == [.createCalendar(name: "Gym", account: "iCloud")])
        let named = try await trace(backend.ask("tool: calendar_create_calendar name=Gym; account=google", calendar: true, calendarWrite: true))
        #expect(changes(named) == [.createCalendar(name: "Gym", account: "Google")])
        let wrong = try await trace(backend.ask("tool: calendar_create_calendar name=Gym; account=Exchange", calendar: true, calendarWrite: true))
        #expect(refusals(wrong).first?.hasPrefix("there is no calendar account called") == true)
        backend.stop()
    }

    @Test func wholeCalendarsCanBeAddedRenamedAndDeletedOnlyWhenThatMakesSense() async throws {
        let backend = calendarService(stubWithTwoEvents())
        func run(_ request: String) async throws -> (text: String, events: [AnswerEvent]) {
            try await trace(backend.ask("tool: \(request)", calendar: true, calendarWrite: true, deletes: .all))
        }
        #expect(changes(try await run("calendar_create_calendar name=Gym")) == [.createCalendar(name: "Gym")])
        #expect(changes(try await run("calendar_rename_calendar name=Work; new_name=Office")) == [.renameCalendar(from: "Work", to: "Office")])
        #expect(changes(try await run("calendar_delete_calendar name=Work")) == [.deleteCalendar(name: "Work")])
        #expect(refusals(try await run("calendar_create_calendar name=home")) == ["there is already a calendar called \"home\""])
        #expect(refusals(try await run("calendar_delete_calendar name=Birthdays")) == ["the calendar \"Birthdays\" cannot be changed"])
        #expect(refusals(try await run("calendar_delete_calendar name=Nope")) == ["there is no calendar called \"Nope\""])
        #expect(refusals(try await run("calendar_rename_calendar name=Work")) == ["the calendar needs a name"])
        // A new event in a named calendar: the calendar must exist.
        let draft = try await run("calendar_create_event title=Gym; start=2026-11-18T18:00; end=2026-11-18T19:00; all_day=false; calendar=Nope")
        #expect(refusals(draft) == ["there is no calendar called \"Nope\""])
        backend.stop()
    }

    @Test func detailsAndTheListOfCalendarsAreReadsAndMarkTheChat() async throws {
        let stub = stubWithTwoEvents()
        stub.notes = "Bring ID"
        stub.guests = ["Sam"]
        let backend = calendarService(stub)
        let delivered = Flag()
        backend.onPersonalDataDelivered { delivered.set(1) }
        let list = try await trace(backend.ask("tool: calendar_list", calendar: true))
        #expect(list.events.prefix(2) == [.readingCalendar, .calendarRead(summary: "your list of calendars", events: -1)])
        #expect(list.text.contains("Home (default for new events)") && list.text.contains("Birthdays (read-only)"))
        #expect(delivered.value == 1)

        _ = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        let details = try await trace(backend.ask("tool: calendar_event_details event=e2", calendar: true))
        #expect(details.events.contains(.calendarRead(summary: "one event's details", events: -1)))
        #expect(details.text.contains("Notes: Bring ID") && details.text.contains("Guests: Sam"))

        let filtered = try await trace(backend.ask("tool: calendar_events start=2026-11-18; end=2026-11-18; search=dent", calendar: true))
        #expect(filtered.events.contains(.calendarRead(summary: "18 Nov", events: 1)))
        #expect(!filtered.text.contains("Standup"))
        // None of these work when the app did not offer the calendar.
        let refused = try await trace(backend.ask("tool: calendar_list", calendar: false))
        #expect(refused.events.first == .calendarFailed("the calendar is not available"))
        backend.stop()
    }

    /// Real model: it must find the event, then prepare the right change, and never claim it was done.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveChange
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(6)))
    func liveChangeAndDeleteRequestsBecomeTheRightPreviews() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let stub = StubCalendar()
        stub.events = [
            CalendarEvent(title: "Dentist", start: tomorrow.addingTimeInterval(10 * 3600), end: tomorrow.addingTimeInterval(11 * 3600),
                          calendar: "Home", location: "Main Street Dental", key: "dentist|1"),
            CalendarEvent(title: "Project review with Priya", start: tomorrow.addingTimeInterval(15 * 3600),
                          end: tomorrow.addingTimeInterval(16 * 3600), calendar: "Work", key: "review|2"),
        ]
        let backend = BackendService(config: config, webSearch: StubSearch(), calendar: stub)
        func ask(_ text: String) async throws -> (text: String, events: [AnswerEvent]) {
            // The same rule the app applies to each message.
            var chat = Conversation()
            let offer = chat.offer(for: text, hasAttachments: false)
            let run = try await trace(backend.ask(text, personal: true, calendar: true, calendarWrite: offer.changes,
                                                  deletes: offer.deletes))
            print("LIVE_CHANGE [\(offer.changes) \(offer.deletes)] \(text) => \(changes(run).map { $0.line() }) | refused \(refusals(run)) | answer: \(run.text)")
            return run
        }

        let moved = try await ask("Move my dentist appointment tomorrow to 2pm")
        if case .update(let original, let after, _)? = changes(moved).first {
            #expect(original.key == "dentist|1")
            #expect(after.start == tomorrow.addingTimeInterval(14 * 3600))
            #expect(after.end == tomorrow.addingTimeInterval(15 * 3600))
            #expect(after.title == "Dentist" && after.location == "Main Street Dental")
        } else {
            Issue.record("no change was prepared for the dentist appointment")
        }
        #expect(changes(moved).count == 1)
        for claim in ["has been moved", "I've moved", "I have moved", "has been changed", "I've changed"] {
            #expect(!moved.text.localizedCaseInsensitiveContains(claim))
        }

        let deleted = try await ask("Delete the project review with Priya tomorrow")
        if case .delete(let snapshot, _)? = changes(deleted).first {
            #expect(snapshot.key == "review|2")
        } else {
            Issue.record("no deletion was prepared for the project review")
        }
        #expect(changes(deleted).count == 1)
        for claim in ["has been deleted", "I've deleted", "I have deleted", "has been removed"] {
            #expect(!deleted.text.localizedCaseInsensitiveContains(claim))
        }

        let renamed = try await ask("Rename my dentist appointment tomorrow to Dental checkup and add a 30 minute alert")
        if case .update(let original, let after, _)? = changes(renamed).first {
            #expect(original.key == "dentist|1")
            #expect(after.title.localizedCaseInsensitiveContains("checkup"))
            #expect(after.alertMinutes == 30)
            #expect(after.start == original.draft.start)
        } else {
            Issue.record("no change was prepared for the rename")
        }

        let made = try await ask("Create a new calendar called Fitness")
        #expect(changes(made) == [.createCalendar(name: "Fitness")])

        // Reading must prepare nothing.
        let read = try await ask("What's on my calendar tomorrow?")
        #expect(changes(read).isEmpty)
        #expect(read.text.contains("Priya"))
        backend.stop()
    }

    /// Real model: it must prepare the right event and must not claim it was added.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveEvent
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveEventRequestBecomesTheRightPreview() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let backend = BackendService(config: config, webSearch: StubSearch(), calendar: StubCalendar())
        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!

        func drafts(_ run: (text: String, events: [AnswerEvent])) -> [EventDraft] {
            run.events.compactMap { if case .changeProposed(.create(let draft)) = $0 { return draft } else { return nil } }
        }

        let run = try await trace(backend.ask("Add lunch with Sam tomorrow at 1pm at Cafe Rio",
                                              personal: true, calendar: true, calendarWrite: true, deletes: .all))
        print("LIVE_EVENT timed: \(drafts(run)) answer: \(run.text)")
        #expect(drafts(run).count == 1)
        if let draft = drafts(run).first {
            #expect(draft.start == tomorrow.addingTimeInterval(13 * 3600))
            #expect(draft.end == tomorrow.addingTimeInterval(14 * 3600))
            #expect(!draft.allDay)
            #expect(draft.title.localizedCaseInsensitiveContains("lunch"))
            #expect(draft.location?.localizedCaseInsensitiveContains("Cafe Rio") == true)
        }
        // It must not say the event is on the calendar already.
        #expect(!run.text.localizedCaseInsensitiveContains("has been added"))
        #expect(!run.text.localizedCaseInsensitiveContains("I've added"))
        #expect(!run.text.localizedCaseInsensitiveContains("I have added"))

        let ranged = try await trace(backend.ask("Put a dentist appointment on my calendar for tomorrow from 9:30 to 10:15 in the morning",
                                                 personal: true, calendar: true, calendarWrite: true, deletes: .all))
        print("LIVE_EVENT range: \(drafts(ranged)) answer: \(ranged.text)")
        #expect(drafts(ranged).first?.start == tomorrow.addingTimeInterval(9.5 * 3600))
        #expect(drafts(ranged).first?.end == tomorrow.addingTimeInterval(10.25 * 3600))

        let allDay = try await trace(backend.ask("Create an all-day event called Mum's birthday tomorrow",
                                                 personal: true, calendar: true, calendarWrite: true, deletes: .all))
        print("LIVE_EVENT all day: \(drafts(allDay)) answer: \(allDay.text)")
        #expect(drafts(allDay).first?.allDay == true)
        #expect(drafts(allDay).first?.start == tomorrow)

        // No day or time given: it should ask, not invent one.
        let vague = try await trace(backend.ask("Add a meeting with Priya to my calendar",
                                                personal: true, calendar: true, calendarWrite: true, deletes: .all))
        print("LIVE_EVENT vague: \(drafts(vague)) answer: \(vague.text)")
        #expect(drafts(vague).isEmpty)

        // An ordinary question prepares nothing.
        let other = try await trace(backend.ask("What is the capital of France?", calendar: true, calendarWrite: true, deletes: .all))
        #expect(drafts(other).isEmpty)
        backend.stop()
    }

    /// The chat must be marked through a path that does not depend on anyone
    /// still reading the answer: here the answer is abandoned as soon as it starts.
    @Test func personalDataIsReportedEvenIfNobodyReadsTheAnswer() async throws {
        let stub = StubCalendar()
        stub.events = [CalendarEvent(title: "Standup", start: Date(timeIntervalSince1970: 1_795_000_000),
                                     end: Date(timeIntervalSince1970: 1_795_001_800), calendar: "Work")]
        let backend = calendarService(stub)
        let delivered = Flag()
        backend.onPersonalDataDelivered { delivered.set(1) }

        let task = Task { try await self.trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true)) }
        #expect(await waitUntil { !stub.ranges.isEmpty })
        // Not cancelled here: the point is that the report arrives by itself.
        #expect(await waitUntil { delivered.value == 1 })
        _ = try? await task.value

        // A read that fails delivers nothing, so nothing is reported.
        let failing = StubCalendar()
        failing.failure = CalendarError.notAllowed
        let other = calendarService(failing)
        let reported = Flag()
        other.onPersonalDataDelivered { reported.set(1) }
        _ = try await trace(other.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        #expect(reported.value == nil)
        backend.stop()
        other.stop()
    }

    @Test func theCalendarIsNotReadUnlessTheAppOfferedItForThatQuestion() async throws {
        let stub = StubCalendar()
        let backend = calendarService(stub)
        let run = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: false))
        #expect(stub.ranges.isEmpty)
        #expect(run.events.first == .calendarFailed("the calendar is not available"))
        #expect(run.text.contains("ok=False"))
        backend.stop()

        // And never when no calendar was supplied at all.
        let none = calendarService(nil)
        let again = try await trace(none.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        #expect(again.events.first == .calendarFailed("the calendar is not available"))
        none.stop()
    }

    @Test func aRefusedPermissionOrBadDatesAreReportedInWords() async throws {
        let stub = StubCalendar()
        stub.failure = CalendarError.notAllowed
        let backend = calendarService(stub)
        let denied = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        #expect(denied.events.contains { event in
            if case .calendarFailed(let why) = event { return why.contains("has not been allowed to use your calendar") }
            return false
        })
        #expect(denied.text.contains("ok=False"))

        let bad = try await trace(backend.ask("calendar: tomorrow tomorrow", calendar: true))
        #expect(bad.events.first == .calendarFailed("the dates asked for were not valid"))
        #expect(stub.ranges.count == 1)     // the bad dates never reached the calendar
        backend.stop()
    }

    @Test func aSlowCalendarReadIsGivenUpOnAndNoLateResultIsShown() async throws {
        let stub = StubCalendar()
        stub.delay = 1.5
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_MOCK_DELAY_MS"] = "1"
        var config = BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", "0"],
            workingDirectory: Self.backendDirectory, environment: environment
        )
        config.searchDeadline = 0.3
        let backend = BackendService(config: config, calendar: stub)
        let run = try await trace(backend.ask("calendar: 2026-11-18 2026-11-18", calendar: true))
        #expect(run.events.contains(.calendarFailed("reading the calendar took too long")))
        #expect(!run.events.contains { if case .calendarRead = $0 { return true } else { return false } })
        backend.stop()
    }

    // The mock backend reports the files it was sent when asked "attachments?".
    @Test func attachedFilesReachTheBackendWithTheQuestionAndWithLaterOnes() async throws {
        let picture = try AttachmentLoader.image(from: Make.solid(width: 800, height: 600, red: 1, green: 0, blue: 0),
                                                 name: "red square.png")
        let notes = Attachment(kind: .text, name: "notes.txt", text: "private notes")
        let backend = service()
        let first = try await trace(backend.ask("attachments?", attachments: [picture, notes]))
        #expect(first.text == "Got 2 attachments (image red square.png, text notes.txt). Earlier turns carried 0.")

        let history = [ChatTurn(role: .user, content: "look", attachments: [picture]),
                       ChatTurn(role: .assistant, content: "A red square.")]
        let later = try await trace(backend.ask("attachments?", history: history))
        #expect(later.text == "Got 0 attachments (none). Earlier turns carried 1.")
        backend.stop()
    }

    /// Real model: it must actually see a picture sent through the whole chain.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveImage
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveImageIsSeenByTheModel() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let backend = BackendService(config: config)

        // A picture with writing in it, like a screenshot.
        let screenshot = Make.png(Make.bitmap(width: 900, height: 300) { context in
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 900, height: 300))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            Make.write("Order confirmed. Your reference number is 7391.", in: context, at: CGPoint(x: 40, y: 170), size: 34)
            Make.write("Delivery: Thursday", in: context, at: CGPoint(x: 40, y: 90), size: 34)
        })
        let picture = try AttachmentLoader.image(from: screenshot, name: "confirmation.png")
        let started = Date()
        let seen = try await trace(backend.ask("What is the reference number in this picture? Reply with the number only.",
                                               attachments: [picture]))
        print("LIVE_IMAGE seconds \(Date().timeIntervalSince(started)) answer: \(seen.text)")
        #expect(seen.text.contains("7391"))

        // A follow-up that only makes sense if the picture travelled with the history.
        let history = [ChatTurn(role: .user, content: "What is the reference number in this picture?", attachments: [picture]),
                       ChatTurn(role: .assistant, content: seen.text)]
        let followUp = try await trace(backend.ask("And which day is the delivery? One word.", history: history))
        print("LIVE_IMAGE follow-up: \(followUp.text)")
        #expect(followUp.text.localizedCaseInsensitiveContains("Thursday"))

        // A document: the answer must come from the file.
        let report = Attachment(kind: .text, name: "report.txt",
                                text: "Internal note. The project codename is Bluebird and the launch date is 14 March.")
        let document = try await trace(backend.ask("What is the project codename? One word.", attachments: [report]))
        print("LIVE_DOCUMENT answer: \(document.text)")
        #expect(document.text.localizedCaseInsensitiveContains("Bluebird"))
        let details = document.events.compactMap { event -> AnswerDetails? in
            if case .finished(_, let details) = event { return details } else { return nil }
        }.first
        #expect(details?.route == "local")
        backend.stop()
    }

    // The mock backend reports the history it was sent when asked "history?".
    @Test func earlierTurnsTravelWithTheQuestionAndSurviveARestart() async throws {
        let backend = service(idleSeconds: 0.4)
        let history = [ChatTurn(role: .user, content: "who won the grand prix"),
                       ChatTurn(role: .assistant, content: "Lando Norris.")]
        let first = try await trace(backend.ask("history?", history: history))
        #expect(first.text == "History has 2 messages. The last thing you said before this was: who won the grand prix")

        let none = try await trace(backend.ask("history?"))
        #expect(none.text.hasPrefix("History has 0 messages."))

        // After the backend has gone idle and restarted, the history still arrives:
        // the app owns the conversation, the backend remembers nothing.
        #expect(await waitUntil { !backend.isRunning })
        let again = try await trace(backend.ask("history?", history: history))
        #expect(again.text.hasPrefix("History has 2 messages."))
        #expect(backend.startCount == 2)
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

    /// The search outlasts the app's deadline. The model must be told it
    /// failed, and the late results must never be shown as sources.
    @Test func aSearchThatOutlastsTheDeadlineShowsNoSources() async throws {
        let stub = StubSearch()
        stub.delay = 1.5
        var environment = ProcessInfo.processInfo.environment
        environment["OMNIS_MOCK_DELAY_MS"] = "1"
        var config = BackendConfig(
            executable: URL(fileURLWithPath: "/usr/bin/env"),
            arguments: ["python3", "-m", "omnis_backend", "--idle-seconds", "0"],
            workingDirectory: Self.backendDirectory, environment: environment
        )
        config.searchDeadline = 0.3
        let backend = BackendService(config: config, webSearch: stub)
        let run = try await trace(backend.ask("search: slow thing"))
        #expect(run.events.contains(.searchFailed("the search took too long")))
        #expect(!run.events.contains { if case .sources = $0 { return true } else { return false } })
        #expect(run.text.contains("ok=False"))

        // Wait past the slow search finishing: still nothing appears for the old request.
        try await Task.sleep(nanoseconds: 1_600_000_000)
        stub.delay = 0
        let next = try await trace(backend.ask("search: quick thing"))
        #expect(next.events.contains(.sources(stub.results)))
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
            case .searching, .sources, .searchFailed, .usage, .readingCalendar, .calendarRead, .calendarFailed, .changeProposed, .eventRefused, .projectProposed: break
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
            case .searching, .sources, .searchFailed, .usage, .readingCalendar, .calendarRead, .calendarFailed, .changeProposed, .eventRefused, .projectProposed: break
            }
        }
        #expect(text.contains("Paris"))
        #expect(!text.contains("</think>"))
        #expect(finished?.model == "gemma4:12b")
        #expect(finished?.details.route == "local")
        #expect((finished?.details.outputTokens ?? 0) > 0)

        // With no Claude key, asking for Claude is answered locally and says so.
        var passedOver: AnswerDetails?
        for try await event in backend.ask("use claude to say hello in one word") {
            if case .finished(_, let details) = event { passedOver = details }
        }
        #expect(passedOver?.route == "local")
        #expect(passedOver?.fallback == "Claude could not be used (it is not set up)")

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

    /// Real model: a follow-up only makes sense if the earlier turns were sent.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveConversation
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveConversationRemembersEarlierTurns() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)
        let backend = BackendService(config: config)

        var chat = Conversation()
        let first = chat.begin(question: "Who wrote Pride and Prejudice? One short sentence.")
        let one = try await trace(backend.ask("Who wrote Pride and Prejudice? One short sentence.", web: false))
        chat.update(first) { $0.text = one.text; $0.state = .done }
        #expect(one.text.contains("Austen"))

        let started = Date()
        let two = try await trace(backend.ask("In what year was she born?", web: false, history: chat.history()))
        print("LIVE_FOLLOWUP seconds \(Date().timeIntervalSince(started)) first: \(one.text) | follow-up: \(two.text)")
        #expect(two.text.contains("1775"))

        // Without the history the same follow-up cannot be answered.
        let alone = try await trace(backend.ask("In what year was she born?", web: false))
        #expect(!alone.text.contains("1775"))
        backend.stop()
    }

    /// Real model, made-up calendar: it must ask for the right day and answer from what comes back.
    ///   OMNIS_LIVE_TESTS=1 swift test --filter liveCalendar
    @Test(.enabled(if: ProcessInfo.processInfo.environment["OMNIS_LIVE_TESTS"] == "1"), .timeLimit(.minutes(5)))
    func liveCalendarQuestionReadsTheRightDay() async throws {
        let ollama = URL(fileURLWithPath: ProcessInfo.processInfo.environment["OMNIS_OLLAMA"] ?? "/opt/homebrew/bin/ollama")
        var config = BackendConfig.python(URL(fileURLWithPath: "/usr/bin/env"), backendDirectory: Self.backendDirectory,
                                          ollama: ollama, idleSeconds: 0)
        config.arguments.insert("python3", at: 0)

        let calendar = Calendar.current
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: Date()))!
        let stub = StubCalendar()
        stub.events = [
            CalendarEvent(title: "Dentist", start: tomorrow.addingTimeInterval(10 * 3600), end: tomorrow.addingTimeInterval(11 * 3600),
                          calendar: "Personal", location: "Main Street Dental"),
            CalendarEvent(title: "Project review with Priya", start: tomorrow.addingTimeInterval(15 * 3600),
                          end: tomorrow.addingTimeInterval(16 * 3600), calendar: "Work"),
        ]
        let backend = BackendService(config: config, webSearch: StubSearch(), calendar: stub)

        let started = Date()
        let run = try await trace(backend.ask("What's on my calendar tomorrow?", personal: true, calendar: true))
        print("LIVE_CALENDAR seconds \(Date().timeIntervalSince(started)) answer: \(run.text)")
        // It asked for exactly tomorrow.
        #expect(stub.ranges.count == 1)
        #expect(stub.ranges.first?.0 == tomorrow)
        #expect(stub.ranges.first?.1 == calendar.date(byAdding: .day, value: 1, to: tomorrow))
        #expect(run.text.localizedCaseInsensitiveContains("Dentist"))
        #expect(run.text.contains("Priya"))
        #expect(run.text.contains("10:00"))
        #expect(!run.events.contains { if case .searching = $0 { return true } else { return false } })

        // A follow-up from the same chat, answered from what was already read.
        let history = [ChatTurn(role: .user, content: "What's on my calendar tomorrow?"),
                       ChatTurn(role: .assistant, content: run.text)]
        let followUp = try await trace(backend.ask("Where is the first one?", history: history, personal: true, calendar: true))
        print("LIVE_CALENDAR follow-up: \(followUp.text)")
        #expect(followUp.text.localizedCaseInsensitiveContains("Main Street"))

        // A question that has nothing to do with the calendar does not read it.
        let before = stub.ranges.count
        let other = try await trace(backend.ask("What is 12 times 12?", calendar: true))
        print("LIVE_CALENDAR unrelated: \(other.text)")
        #expect(stub.ranges.count == before)
        #expect(other.text.contains("144"))

        // An empty day is reported as empty, not invented.
        stub.events = []
        let empty = try await trace(backend.ask("Do I have anything on next Saturday?", personal: true, calendar: true))
        print("LIVE_CALENDAR empty: \(empty.text)")
        #expect(!empty.text.localizedCaseInsensitiveContains("Dentist"))
        backend.stop()
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
