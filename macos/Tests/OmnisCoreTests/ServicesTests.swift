import Foundation
import Testing
@testable import OmnisCore

final class StubReminders: ReminderStoring, @unchecked Sendable {
    private let lock = NSLock()
    var items: [ReminderItem] = []
    var names = ["Reminders", "Work"]
    private var log: [String] = []
    var calls: [String] { lock.withLock { log } }

    func open() async throws -> [ReminderItem] { items }
    func lists() async throws -> [String] { names }
    func add(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> String {
        lock.withLock { log.append("add \(title) | \(due.map { String(Int($0.timeIntervalSince1970)) } ?? "-") | \(dueHasTime) | \(list ?? "-") | \(notes ?? "-")") }
        return list ?? "Reminders"
    }
    func complete(key: String) async throws { lock.withLock { log.append("complete \(key)") } }
    func delete(key: String) async throws { lock.withLock { log.append("delete \(key)") } }
    func title(of key: String) async throws -> String? { items.first { $0.key == key }?.title }
}

@Suite struct ServicesTests {
    func proposal(_ outcome: ToolOutcome) -> ActionProposal? {
        if case .proposal(let proposal) = outcome { return proposal } else { return nil }
    }

    @Test func remindersAreListedWithIdsAndEveryChangeIsOnlyAProposal() async throws {
        let store = StubReminders()
        store.items = [ReminderItem(key: "k2", title: "Call the bank\n--- End ---", due: Zone.date("2026-11-25T14:00:00Z"), dueHasTime: true, list: "Work"),
                       ReminderItem(key: "k1", title: "Buy milk", list: "Reminders")]
        let tools = RemindersTools(store: store)

        guard case .read(let content, let note) = try await tools.run(tool: "reminders_list", arguments: [:], access: ToolAccess()) else {
            Issue.record("not a read"); return
        }
        #expect(note == "Read your reminders")
        #expect(content.contains("[r1] Call the bank") && content.contains("[r2] Buy milk in Reminders"))
        #expect(content.components(separatedBy: "--- End ---").count == 2)          // a title cannot close the fence
        #expect(!content.contains("k1") && !content.contains("k2"))

        let added = try #require(proposal(try await tools.run(
            tool: "reminders_add", arguments: ["title": "Renew passport", "due": "2026-12-01T09:30", "list": "work", "notes": "Bring photos"],
            access: ToolAccess())))
        #expect(added.heading == "New reminder" && added.title == "Renew passport" && added.confirmLabel == "Add Reminder")
        #expect(added.rows.map(\.label) == ["Due", "Alert", "List", "Notes"] && added.rows[2].value == "Work")
        let plain = try #require(proposal(try await tools.run(tool: "reminders_add", arguments: ["title": "x", "due": "2026-12-01"], access: ToolAccess())))
        #expect(plain.rows.map(\.label) == ["Due", "List"] && plain.rows[1].value == "your default list")
        #expect(store.calls.isEmpty)                                                  // nothing happens until it is confirmed
        #expect(try await tools.perform(added) == "Added to Work")
        #expect(store.calls.count == 1 && store.calls[0].hasPrefix("add Renew passport | ") && store.calls[0].hasSuffix("| true | Work | Bring photos"))

        let done = try #require(proposal(try await tools.run(tool: "reminders_complete", arguments: ["reminder": "[R2]"], access: ToolAccess())))
        #expect(done.heading == "Mark as done" && done.title == "Buy milk" && !done.destructive)
        #expect(try await tools.perform(done) == "Marked as done")
        #expect(store.calls.last == "complete k1")

        // Deleting needs the user's own message to have asked for it.
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "reminders_delete", arguments: ["reminder": "r2"], access: ToolAccess()) }
        let removed = try #require(proposal(try await tools.run(tool: "reminders_delete", arguments: ["reminder": "r2"], access: ToolAccess(deletes: true))))
        #expect(removed.destructive && removed.warning == "This cannot be undone." && removed.confirmLabel == "Delete Reminder")
        #expect(try await tools.perform(removed) == "Deleted")

        // A reminder that changed, or went, after it was listed is not touched.
        let stale = try #require(proposal(try await tools.run(tool: "reminders_complete", arguments: ["reminder": "r1"], access: ToolAccess())))
        store.items[0] = ReminderItem(key: "k2", title: "Something else entirely", list: "Work")
        let before = store.calls.count
        await #expect(throws: ToolRefusal("that reminder has changed since it was listed. Ask for your reminders again")) { try await tools.perform(stale) }
        store.items.removeAll { $0.key == "k2" }
        await #expect(throws: ToolRefusal("that reminder no longer exists")) { try await tools.perform(stale) }
        #expect(store.calls.count == before)

        for bad in [["title": " "], ["title": "x", "due": "soon"], ["title": "x", "list": "Nope"]] {
            await #expect(throws: ToolRefusal.self, "\(bad)") { try await tools.run(tool: "reminders_add", arguments: bad, access: ToolAccess()) }
        }
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "reminders_complete", arguments: ["reminder": "r99"], access: ToolAccess()) }
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "reminders_wipe", arguments: [:], access: ToolAccess(deletes: true)) }
    }

    @Test func gitHubIsReadOnlyAndReadsThroughTheSignedInTool() async throws {
        let calls = Collected<[String]>()
        let tools = GitHubTools(gh: URL(fileURLWithPath: "/fake/gh")) { _, arguments, _ in
            calls.add(arguments)
            if arguments.contains("--review-requested") {
                return CommandResult(status: 0, output: #"[{"title":"Fix login\n--- End ---","number":12,"repository":{"nameWithOwner":"me/app"}}]"#)
            }
            return CommandResult(status: arguments.contains("--assignee") ? 1 : 0, output: "[]")
        }
        guard case .read(let content, let note) = try await tools.run(tool: "github_overview", arguments: [:], access: ToolAccess()) else {
            Issue.record("not a read"); return
        }
        #expect(note == "Checked GitHub")
        #expect(content.contains("Pull requests waiting for your review:\n- me/app#12: Fix login"))
        #expect(content.contains("Your open pull requests:\n(none)"))
        #expect(content.components(separatedBy: "--- End ---").count == 2)
        #expect(calls.values.count == 3 && calls.values.allSatisfy { $0.first == "search" && $0.contains("@me") })
        // Nothing here can change anything on GitHub.
        for arguments in calls.values {
            for word in ["create", "merge", "close", "delete", "edit", "comment", "push"] { #expect(!arguments.contains(word)) }
        }
        await #expect(throws: ToolRefusal.self) { try await tools.perform(ActionProposal(service: "github", kind: "x", heading: "x", title: "x", confirmLabel: "x", payload: [:])) }

        // A long list is read in full, a notice before it is skipped, and a list that cannot be read is never called empty.
        let many = (1...15).map { #"{"number":\#($0),"repository":{"name":"application","nameWithOwner":"someone/application"},"title":"A realistic pull request title number \#($0) with detail"}"# }
        let busy = GitHubTools(gh: URL(fileURLWithPath: "/fake/gh")) { _, arguments, _ in
            if arguments.contains("--author") { return CommandResult(status: 0, output: "A new release of gh is available\n[" + many.joined(separator: ",") + "]") }
            if arguments.contains("--assignee") { return CommandResult(status: 0, output: "{broken") }
            return CommandResult(status: 0, output: "[]")
        }
        guard case .read(let full, _) = try await busy.run(tool: "github_overview", arguments: [:], access: ToolAccess()) else { Issue.record("not a read"); return }
        #expect(full.components(separatedBy: "someone/application#").count == 16)
        #expect(full.contains("#15: A realistic pull request title number 15"))
        #expect(full.contains("Open issues assigned to you:\n(this list could not be read"))
        #expect(full.contains("Pull requests waiting for your review:\n(none)"))

        let down = GitHubTools(gh: URL(fileURLWithPath: "/fake/gh")) { _, _, _ in CommandResult(status: 1, output: "error: not logged in") }
        await #expect(throws: ToolRefusal.self) { try await down.run(tool: "github_overview", arguments: [:], access: ToolAccess()) }
    }

    @Test func spotifyRunsOnlyFixedScriptsAndNeverPutsModelTextInOne() async throws {
        let calls = Collected<[String]>()
        let tools = SpotifyTools { program, arguments, _ in
            calls.add([program.lastPathComponent] + arguments)
            if arguments.last?.contains("player state") == true { return CommandResult(status: 0, output: "playing\u{1F}Song | \"A\"\u{1F}The Band\n") }
            return CommandResult(status: 0, output: "")
        }
        guard case .read(let playing, _) = try await tools.run(tool: "spotify_now_playing", arguments: [:], access: ToolAccess()) else {
            Issue.record("not a read"); return
        }
        #expect(playing == "Playing: Song | \"A\" by The Band.")

        guard case .done(let result, let note) = try await tools.run(tool: "spotify_control", arguments: ["action": "NEXT"], access: ToolAccess()) else {
            Issue.record("not done"); return
        }
        #expect(note == "Controlled Spotify" && result.hasPrefix("Done. Playing: Song"))
        #expect(calls.values.contains(["osascript", "-e", "tell application \"Spotify\" to next track"]))
        // An action that is not on the list is refused, not turned into a script.
        await #expect(throws: ToolRefusal.self) {
            try await tools.run(tool: "spotify_control", arguments: ["action": "quit\" & (do shell script \"x\") & \""], access: ToolAccess())
        }
        let before = calls.values.count
        _ = try await tools.run(tool: "spotify_search", arguments: ["query": "daft punk\"; open /etc"], access: ToolAccess())
        #expect(calls.values.count == before + 1)
        #expect(calls.values.last == ["open", "spotify:search:daft%20punk%22%3B%20open%20%2Fetc"])
        _ = try await tools.run(tool: "spotify_search", arguments: ["query": "café"], access: ToolAccess())
        #expect(calls.values.last == ["open", "spotify:search:caf%C3%A9"])
        #expect(SpotifyTools.scripts.values.allSatisfy { $0.hasPrefix("tell application \"Spotify\" to ") })

        let blocked = SpotifyTools { _, _, _ in CommandResult(status: 1, output: "execution error: Not authorised to send Apple events to Spotify. (-1743)") }
        do {
            _ = try await blocked.run(tool: "spotify_control", arguments: ["action": "pause"], access: ToolAccess())
            Issue.record("should have been refused")
        } catch {
            #expect(error.localizedDescription.contains("has not been allowed to control Spotify"))
        }
    }

    @Test func claudeCanOpenOnlyWhatIsInTheUsersListAndNeverALauncher() async throws {
        let performer = RecordingPerformer()
        let tools = AppsTools(registry: { sampleRegistry() }, performer: performer)
        guard case .done(let said, let note) = try await tools.run(tool: "apps_open", arguments: ["name": "safari"], access: ToolAccess(opens: true)) else {
            Issue.record("not done"); return
        }
        #expect(said == "Opened Safari." && note == "Opened Safari")
        #expect(performer.plans == [.openApplication(URL(fileURLWithPath: "/Applications/Safari.app"))])
        // A project opens in the editor.
        _ = try await tools.run(tool: "apps_open", arguments: ["name": "omnis"], access: ToolAccess(opens: true))
        #expect(performer.plans.count == 2)
        // Not in the list, a path, or a launcher (which runs a program): refused, and nothing is opened.
        for name in ["Terminal", "/bin/sh", "../../etc", "Ghidra", ""] {
            await #expect(throws: ToolRefusal.self, "\(name)") { try await tools.run(tool: "apps_open", arguments: ["name": name], access: ToolAccess(opens: true)) }
        }
        // Never from a chat that holds a file.
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "apps_open", arguments: ["name": "safari"], access: ToolAccess()) }
        #expect(performer.plans.count == 2)
    }

    @Test func whatIsSaidAloudToOpenSomethingIsStillAPlainLaunch() {
        let registry = sampleRegistry()
        for said in ["Open Safari.", "Can you open Safari for me?", "Okay, open Safari please", "I want to open Safari real quick",
                     "Could you launch Safari right now", "Go ahead and open Safari, thank you"] {
            let suggestion = LaunchSuggestion.suggest(for: said, registry: registry)
            #expect(suggestion.preselect && suggestion.entries.first?.name == "Safari", "\(said)")
            #expect(LaunchSuggestion.spoken(said, registry: registry)?.name == "Safari", "\(said)")
        }
        // A question that happens to contain a name is still a question.
        for said in ["what is Safari", "open Safari and tell me the news", "is Xcode open"] {
            #expect(!LaunchSuggestion.suggest(for: said, registry: registry).preselect, "\(said)")
            #expect(LaunchSuggestion.spoken(said, registry: registry) == nil, "\(said)")
        }
        // By voice the words must ask for it, a launcher is never started, and two that fit equally are not guessed between.
        #expect(LaunchSuggestion.spoken("Safari", registry: registry) == nil)
        #expect(LaunchSuggestion.spoken("open Ghidra", registry: registry) == nil)
        #expect(LaunchSuggestion.suggest(for: "open Ghidra", registry: registry).preselect)
        #expect(LaunchSuggestion.spoken("open voy", registry: sampleRegistry(aliases: [:])) == nil)
        #expect(LaunchSuggestion.spoken("open voyager", registry: registry)?.name == "VoyagerAI")
    }

    private struct Catalogue: SpotifyCatalogue {
        var isConnected = true
        var found: [SpotifyItem] = []
        var mine: [SpotifyItem] = []
        func search(_ query: String, kind: SpotifyItem.Kind) async throws -> [SpotifyItem] { found.filter { $0.kind == kind } }
        func playlists() async throws -> [SpotifyItem] { mine }
    }

    @Test func aNamedSongIsFoundAndPlayedAndOnlySpotifysOwnAddressesReachTheApp() async throws {
        let calls = Collected<[String]>()
        let run: CommandRunner = { program, arguments, _ in
            calls.add([program.lastPathComponent] + arguments)
            return CommandResult(status: 0, output: "")
        }
        let one = SpotifyItem(kind: .track, id: "4uLU6hMCjMI75M1A2tKUQC", name: "Never Gonna Give You Up", by: "Rick Astley")
        let two = SpotifyItem(kind: .track, id: "7GhIk7Il098yCjg4BQjzvb", name: "Never Gonna Give You Up (Live)", by: "Rick Astley")
        let gym = SpotifyItem(kind: .playlist, id: "37i9dQZF1DX76Wlfdnj7AP", name: "Gym Mix", by: "me")
        let tools = SpotifyTools(catalogue: Catalogue(found: [one, two, SpotifyItem(kind: .playlist, id: "37i9dQZF1DXcBWIGoYBM5M", name: "Gym Hits", by: "Spotify")],
                                                      mine: [gym]), run: run)
        guard case .done(let said, _) = try await tools.run(tool: "spotify_play", arguments: ["query": "never gonna give you up"], access: ToolAccess()) else {
            Issue.record("not done"); return
        }
        #expect(said.hasPrefix("Now playing Never Gonna Give You Up by Rick Astley.") && said.contains("s2: Never Gonna Give You Up (Live)"))
        // The script is fixed text; what to play is handed over beside it.
        #expect(calls.values.last == ["osascript", "-e", SpotifyTools.playScript, "spotify:track:4uLU6hMCjMI75M1A2tKUQC"])
        #expect(!SpotifyTools.playScript.contains("spotify:"))
        // "The other one" is played from the last matches without searching again.
        _ = try await tools.run(tool: "spotify_play", arguments: ["pick": "s2"], access: ToolAccess())
        #expect(calls.values.last?.last == "spotify:track:7GhIk7Il098yCjg4BQjzvb")
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "spotify_play", arguments: ["pick": "s9"], access: ToolAccess()) }
        // A playlist of the user's own comes before anyone else's of a similar name.
        _ = try await tools.run(tool: "spotify_play", arguments: ["query": "my gym playlist".replacingOccurrences(of: "my ", with: ""), "kind": "playlist"], access: ToolAccess())
        #expect(calls.values.last?.last == "spotify:playlist:37i9dQZF1DX76Wlfdnj7AP")
        // The words searched for go to Spotify, so the tool follows the same rule as a web search.
        #expect(tools.outwardTools.contains("spotify_play"))

        // An identifier that is not what Spotify issues never reaches the app.
        #expect(SpotifyItem(kind: .track, id: "x\" & (do shell script \"y\")", name: "a", by: "b").uri == nil)
        #expect(SpotifyAccount.item(["id": "short", "name": "a"], kind: .track) == nil)
        let before = calls.values.count
        let empty = SpotifyTools(catalogue: Catalogue(found: []), run: run)
        await #expect(throws: ToolRefusal.self) { try await empty.run(tool: "spotify_play", arguments: ["query": "nothing"], access: ToolAccess()) }
        // Not connected: the user is told how, and nothing is run.
        let off = SpotifyTools(catalogue: Catalogue(isConnected: false), run: run)
        do {
            _ = try await off.run(tool: "spotify_play", arguments: ["query": "anything"], access: ToolAccess())
            Issue.record("should have been refused")
        } catch { #expect(error.localizedDescription.contains("/spotify")) }
        #expect(calls.values.count == before)
    }

    private final class MemoryStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var kept: [String: Data] = [:]
        func read(service: String, account: String) -> Data? { lock.withLock { kept[service + account] } }
        func write(_ data: Data, service: String, account: String) { lock.withLock { kept[service + account] = data } }
        func delete(service: String, account: String) { lock.withLock { kept[service + account] = nil } }
    }

    @Test func theSpotifySignInAsksOnlyToReadAndRefusesAReplyItDidNotStart() throws {
        let url = SpotifyAuth.authorizeURL(clientID: String(repeating: "a", count: 32), state: "st", verifier: "ver")
        let items = Dictionary(uniqueKeysWithValues: (URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []).map { ($0.name, $0.value ?? "") })
        #expect(url.host == "accounts.spotify.com" && items["redirect_uri"] == "http://127.0.0.1:43821/callback")
        // Reading only: nothing that could play, change or save.
        #expect(items["scope"] == "playlist-read-private playlist-read-collaborative user-library-read")
        #expect(items["code_challenge_method"] == "S256" && items["code_challenge"] == SpotifyAuth.challenge(for: "ver") && items["code_challenge"] != "ver")
        // RFC 7636's own example.
        #expect(SpotifyAuth.challenge(for: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(try SpotifyAuth.code(fromRequest: "GET /callback?code=abc&state=st HTTP/1.1", state: "st") == "abc")
        for line in ["GET /callback?code=abc&state=other HTTP/1.1", "GET /callback?code=abc HTTP/1.1", "GET /other?code=abc&state=st HTTP/1.1",
                     "POST /callback?code=abc&state=st HTTP/1.1", "GET /callback?error=access_denied&state=st HTTP/1.1", ""] {
            #expect(throws: ToolRefusal.self, "\(line)") { try SpotifyAuth.code(fromRequest: line, state: "st") }
        }
        #expect(SpotifyAuth.isClientID("0123456789abcdef0123456789abcdef") && !SpotifyAuth.isClientID("not-an-id") && !SpotifyAuth.isClientID(""))
        #expect(SlashCommand.parse("/spotify 0123456789abcdef0123456789abcdef") == .spotifyConnect("0123456789abcdef0123456789abcdef"))
        #expect(SlashCommand.parse("/spotify") == .spotifyHelp && SlashCommand.parse("/spotify off") == .spotifyOff)
        // Something else knocking on the door during a sign-in is told apart from Spotify's reply.
        #expect(SpotifyAuth.carries(state: "st", request: "GET /callback?code=abc&state=st HTTP/1.1"))
        #expect(!SpotifyAuth.carries(state: "st", request: "GET /callback HTTP/1.1") && !SpotifyAuth.carries(state: "st", request: "GET /callback?state=x HTTP/1.1"))
    }

    @Test func aWholeSpotifySignInRunsFromTheBrowserComingBackToTheSignInBeingKept() async throws {
        let store = MemoryStore()
        let defaults = UserDefaults(suiteName: "omnis-test-\(UUID().uuidString)")!
        let asked = Collected<String>()
        let account = SpotifyAccount(fetch: { request in
            asked.add(request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? "")
            return (Data(#"{"access_token":"a1","refresh_token":"r1","expires_in":3600}"#.utf8),
                    HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }, store: store, defaults: defaults)
        // The "browser": first a stray page calling the address, which must not end the sign-in, then Spotify's real reply.
        try await account.connect(clientID: String(repeating: "c", count: 32)) { page in
            let state = URLComponents(url: page, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "state" }?.value ?? ""
            Task {
                _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:43821/callback?code=stolen&state=wrong")!)
                _ = try? await URLSession.shared.data(from: URL(string: "http://127.0.0.1:43821/callback?code=the-code&state=\(state)")!)
            }
        }
        #expect(account.isConnected)
        #expect(asked.values.count == 1 && asked.values[0].contains("code=the-code") && asked.values[0].contains("code_verifier=")
            && asked.values[0].contains("grant_type=authorization_code"))
        #expect(store.read(service: "local.omnis.app.spotify", account: "tokens") != nil)
    }

    @Test func spotifyIsSearchedWithTheSignInAndASignInThatHasRunOutIsRenewed() async throws {
        let store = MemoryStore()
        let defaults = UserDefaults(suiteName: "omnis-test-\(UUID().uuidString)")!
        defaults.set(String(repeating: "b", count: 32), forKey: "OMNISSpotifyClientID")
        let old = #"{"access":"stale","refresh":"keep-me","expires":0}"#
        store.write(Data(old.utf8), service: "local.omnis.app.spotify", account: "tokens")
        let seen = Collected<String>()
        let account = SpotifyAccount(fetch: { request in
            let url = request.url!
            seen.add("\(request.httpMethod ?? "") \(url.host ?? "")\(url.path) \(request.value(forHTTPHeaderField: "Authorization") ?? "") "
                + (request.httpBody.flatMap { String(data: $0, encoding: .utf8) } ?? url.query ?? ""))
            let ok = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
            if url.host == "accounts.spotify.com" { return (Data(#"{"access_token":"fresh","expires_in":3600}"#.utf8), ok) }
            let body = #"{"tracks":{"items":[{"id":"4uLU6hMCjMI75M1A2tKUQC","name":"Song","artists":[{"name":"A"},{"name":"B"}]},{"id":"bad id","name":"x"}]}}"#
            return (Data(body.utf8), ok)
        }, store: store, defaults: defaults)
        #expect(account.isConnected)
        let found = try await account.search("a song", kind: .track)
        #expect(found == [SpotifyItem(kind: .track, id: "4uLU6hMCjMI75M1A2tKUQC", name: "Song", by: "A and B")])
        #expect(seen.values.count == 2)
        #expect(seen.values[0].hasPrefix("POST accounts.spotify.com/api/token") && seen.values[0].contains("grant_type=refresh_token")
            && seen.values[0].contains("refresh_token=keep-me"))
        #expect(seen.values[1].hasPrefix("GET api.spotify.com/v1/search Bearer fresh") && seen.values[1].contains("type=track"))
        // The renewed sign-in is kept, with the long-lived half Spotify did not send again.
        let kept = String(data: store.read(service: "local.omnis.app.spotify", account: "tokens") ?? Data(), encoding: .utf8) ?? ""
        #expect(kept.contains("fresh") && kept.contains("keep-me"))
        // Spotify being busy does not throw the sign-in away; Spotify refusing it does.
        for (status, body, stays) in [(503, "{}", true), (400, #"{"error":"invalid_grant"}"#, false)] {
            let kept = MemoryStore()
            kept.write(Data(old.utf8), service: "local.omnis.app.spotify", account: "tokens")
            let shaky = SpotifyAccount(fetch: { request in
                (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }, store: kept, defaults: defaults)
            await #expect(throws: ToolRefusal.self) { try await shaky.search("x", kind: .track) }
            #expect(shaky.isConnected == stays, "\(status)")
        }
        account.disconnect()
        #expect(!account.isConnected && store.read(service: "local.omnis.app.spotify", account: "tokens") == nil)
    }

    @Test func aProposedChangeFromAServiceRunsOnceAndReachesLaterTurns() {
        var chat = Conversation()
        let answer = chat.begin(question: "remind me to call the bank")
        let action = ActionProposal(service: "reminders", kind: "add_reminder", heading: "New reminder", title: "Call the bank",
                                    confirmLabel: "Add Reminder", payload: ["action": "add", "title": "Call the bank"])
        chat.add(action, to: answer)
        chat.add(ActionProposal(service: "reminders", kind: "add_reminder", heading: "New reminder", title: "Call the bank",
                                confirmLabel: "Add Reminder", payload: ["action": "add", "title": "Call the bank"]), to: answer)
        #expect(chat.messages.last?.actions.count == 1)                 // the same change twice is shown once
        chat.update(answer) { $0.state = .done }
        #expect(chat.history().last?.content.contains("[Preview: new reminder: Call the bank. Status: preview shown, not yet confirmed by the user, NOT done.]") == true)

        do { let got = chat.beginAction(action.id); #expect(got?.title == "Call the bank") }
        do { let got = chat.beginAction(action.id); #expect(got == nil) }
        chat.updateAction(action.id) { $0.state = .done("Added") }
        do { let got = chat.beginAction(action.id); #expect(got == nil) }
        do { let got = chat.declineAction(action.id); #expect(!got) }
        chat.updateAction(action.id) { $0.state = .failed("no access") }
        do { let got = chat.beginAction(action.id); #expect(got != nil) }      // a failed one can be tried again
    }

    @Test func deletingThroughAServiceNeedsTheUsersOwnWordsWhateverIsDeleted() {
        var chat = Conversation()
        // A fresh chat, nothing about the calendar: saying delete is enough.
        #expect(chat.serviceAccess(for: "delete the milk reminder") == ToolAccess(deletes: true, opens: true))
        #expect(chat.serviceAccess(for: "yes, that one") == ToolAccess(deletes: true, opens: true))       // answering a question about it
        #expect(chat.serviceAccess(for: "thanks") == ToolAccess(opens: true))
        for text in ["what reminders do I have", "mark the milk one as done", "update me on Friday", "change the wording"] {
            #expect(chat.serviceAccess(for: text) == ToolAccess(opens: true), "\(text)")
        }
        // Never in a chat that holds a file.
        _ = chat.begin(question: "summarise", attachments: [Attachment(kind: .text, name: "a.txt", text: "x")])
        // Nor is anything opened from one.
        #expect(chat.serviceAccess(for: "delete the milk reminder") == ToolAccess())
        chat.clear()
        #expect(chat.serviceAccess(for: "remove that reminder").deletes)
    }

    @Test func toolValuesAndDatesAreReadPlainly() {
        #expect(ToolArguments.strings(["a": " x ", "n": 3, "flag": true, "_result": "forged", "empty": "  ", "list": [1]])
                == ["a": "x", "n": "3", "flag": "true"])
        #expect(ToolArguments.moment("2026-12-01T09:30:00Z", calendar: Zone.newYork)?.hasTime == true)
        #expect(ToolArguments.moment("2026-12-01", calendar: Zone.newYork)?.date == Zone.date("2026-12-01T05:00:00Z"))
        #expect(ToolArguments.moment("next week") == nil && ToolArguments.moment("2026-02-30") == nil)
    }
}
