import Foundation
import Testing
@testable import OmnisCore

final class FakeContainer: ContainerControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var startCount = 0
    private var stopCount = 0
    private var running = false
    var startError: WebSearchError?
    /// If false, `start` succeeds but the service never becomes healthy.
    var becomesHealthy = true

    var starts: Int { lock.withLock { startCount } }
    var stops: Int { lock.withLock { stopCount } }
    var isRunning: Bool { lock.withLock { running } }

    func start() async throws {
        if let startError { throw startError }
        lock.withLock { startCount += 1; running = becomesHealthy }
    }

    func stop() async {
        lock.withLock { stopCount += 1; running = false }
    }

    func setRunning(_ value: Bool) { lock.withLock { running = value } }
}

func json(_ results: [[String: Any]]) -> Data {
    try! JSONSerialization.data(withJSONObject: ["query": "q", "results": results, "answers": []])
}

let twoGood: [[String: Any]] = [
    ["title": "What is the Max plan?", "url": "https://support.example/max", "content": "More usage.", "engines": ["a"]],
    ["title": "Pricing", "url": "https://example.com/pricing", "content": "Free, Pro, Max."],
]

@Suite struct SearXNGResultsTests {
    @Test func readsTitleAddressAndExcerpt() throws {
        let results = try SearXNGResults.parse(json(twoGood))
        #expect(results == [
            SearchResult(title: "What is the Max plan?", url: URL(string: "https://support.example/max")!, snippet: "More usage."),
            SearchResult(title: "Pricing", url: URL(string: "https://example.com/pricing")!, snippet: "Free, Pro, Max."),
        ])
        #expect(results[0].host == "support.example")
    }

    @Test func onlyOrdinaryWebPagesSurvive() throws {
        let hostile: [[String: Any]] = [
            ["title": "file", "url": "file:///System/Applications/Calculator.app"],
            ["title": "plain http", "url": "http://example.com/"],
            ["title": "script", "url": "javascript:alert(1)"],
            ["title": "prefs", "url": "x-apple.systempreferences:com.apple.preference.security"],
            ["title": "with login", "url": "https://user:pass@example.com/"],
            ["title": "no host", "url": "https:///path"],
            ["title": "", "url": "https://no-title.example/"],
            ["title": "not a string", "url": 7],
            ["title": "too long", "url": "https://example.com/" + String(repeating: "a", count: 3000)],
            ["title": "Good one", "url": "HTTPS://Good.example/page"],
        ]
        let results = try SearXNGResults.parse(json(hostile + ["junk"].map { ["title": $0] }))
        #expect(results.map(\.title) == ["Good one"])
    }

    @Test func textIsFlattenedAndTrimmed() throws {
        let messy: [[String: Any]] = [[
            "title": "  Line one\nline two\u{0007}\t tabbed  ",
            "url": "https://example.com/a",
            "content": String(repeating: "word ", count: 500),
        ]]
        let result = try #require(try SearXNGResults.parse(json(messy)).first)
        #expect(result.title == "Line one line two tabbed")
        #expect(result.snippet.count == 500)
        #expect(!result.snippet.contains("\n"))
    }

    @Test func atMostSixAndNoDuplicates() throws {
        let many = (0..<30).map { ["title": "T\($0)", "url": "https://example.com/\($0 / 2)"] as [String: Any] }
        let results = try SearXNGResults.parse(json(many))
        #expect(results.count == 6)
        #expect(Set(results.map(\.url)).count == 6)
    }

    @Test func unreadableRepliesAreAnError() {
        for bad in ["", "not json", "[1,2]", #"{"results":"none"}"#, #"{"query":"q"}"#] {
            #expect(throws: WebSearchError.unreadable) { try SearXNGResults.parse(Data(bad.utf8)) }
        }
        #expect((try? SearXNGResults.parse(json([])))?.isEmpty == true)
    }
}

@Suite struct SearXNGContainerTests {
    @Test func theContainerIsReachableFromThisMacOnly() {
        let container = SearXNGContainer(docker: URL(fileURLWithPath: "/usr/local/bin/docker"),
                                         settingsDirectory: URL(fileURLWithPath: "/Users/someone/Library/Application Support/OMNIS/searxng"),
                                         port: 18888)
        #expect(container.startArguments == [
            "run", "--detach", "--rm", "--name", "omnis-searxng",
            "--publish", "127.0.0.1:18888:8080",
            "--volume", "/Users/someone/Library/Application Support/OMNIS/searxng:/etc/searxng",
            "searxng/searxng:latest",
        ])
        #expect(container.stopArguments == ["stop", "--time", "2", "omnis-searxng"])
        #expect(!container.startArguments.contains { $0.hasPrefix("0.0.0.0") || $0 == "--privileged" || $0.contains("--network") })
    }

    @Test func settingsAreWrittenOnceAndKeptPrivate() throws {
        let scratch = try Scratch()
        let directory = scratch.url.appendingPathComponent("searxng")
        try SearXNGContainer.writeSettingsIfNeeded(in: directory)
        let file = directory.appendingPathComponent("settings.yml")
        let first = try String(contentsOf: file, encoding: .utf8)
        #expect(first.contains("- json"))
        #expect(first.contains("# omnis-settings: 2"))
        for engine in ["bing", "yahoo", "mojeek", "startpage", "wikipedia"] {
            #expect(first.contains("  - name: \(engine)\n    disabled: false"))
        }
        #expect(first.contains("secret_key: \""))
        let attributes = FileManager.default
        #expect(try attributes.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try attributes.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int == 0o700)

        try SearXNGContainer.writeSettingsIfNeeded(in: directory)
        #expect(try String(contentsOf: file, encoding: .utf8) == first)

        // A file from an older version of OMNIS is replaced with the current settings.
        try "# old\nuse_default_settings: true\n".write(to: file, atomically: true, encoding: .utf8)
        try SearXNGContainer.writeSettingsIfNeeded(in: directory)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("- name: bing"))

        // The file it replaced is kept beside it.
        #expect(try String(contentsOf: directory.appendingPathComponent("settings.yml.bak"), encoding: .utf8)
            == "# old\nuse_default_settings: true\n")

        // Each install gets its own secret.
        let other = scratch.url.appendingPathComponent("other")
        try SearXNGContainer.writeSettingsIfNeeded(in: other)
        #expect(try String(contentsOf: other.appendingPathComponent("settings.yml"), encoding: .utf8) != first)
    }

    @Test func aMissingDockerIsNamedAsSuch() async {
        let scratch = try! Scratch()
        let container = SearXNGContainer(docker: URL(fileURLWithPath: "/definitely/not/docker"), settingsDirectory: scratch.url)
        await #expect(throws: WebSearchError.dockerMissing) { try await container.start() }
        await container.stop()  // must not crash
    }

    @Test func aDockerThatIsNotRunningIsNamedAsSuch() async throws {
        let scratch = try Scratch()
        let fake = try scratch.file("docker", contents: "#!/bin/sh\necho 'Cannot connect to the Docker daemon at unix:///x. Is the docker daemon running?' >&2\nexit 1\n", executable: true)
        let container = SearXNGContainer(docker: fake, settingsDirectory: scratch.url.appendingPathComponent("s"))
        await #expect(throws: WebSearchError.dockerNotRunning) { try await container.start() }
    }

    @Test func aLeftoverContainerOfOursIsReused() async throws {
        let scratch = try Scratch()
        let fake = try scratch.file("docker", contents: "#!/bin/sh\necho 'docker: Error response from daemon: Conflict. The container name \"/omnis-searxng\" is already in use by container' >&2\nexit 125\n", executable: true)
        let container = SearXNGContainer(docker: fake, settingsDirectory: scratch.url.appendingPathComponent("s"))
        try await container.start()
    }

    @Test func anyOtherStartFailureIsReportedWithItsReason() async throws {
        let scratch = try Scratch()
        let fake = try scratch.file("docker", contents: "#!/bin/sh\necho 'no space left on device' >&2\nexit 1\n", executable: true)
        let container = SearXNGContainer(docker: fake, settingsDirectory: scratch.url.appendingPathComponent("s"))
        await #expect(throws: WebSearchError.startFailed("no space left on device\n")) { try await container.start() }
    }
}

@Suite struct SearXNGSearchTests {
    /// A fake search service: healthy exactly when the fake container is running.
    func fetcher(_ container: FakeContainer, body: Data = json(twoGood), status: Int = 200,
                 seen: Flag? = nil, urls: Recorder? = nil) -> SearXNGSearch.Fetch {
        { url in
            urls?.add(url)
            guard container.isRunning else { throw URLError(.cannotConnectToHost) }
            if url.path == "/healthz" { return (Data("OK".utf8), 200) }
            seen?.set(1)
            return (body, status)
        }
    }

    @Test func startsTheContainerOnTheFirstSearchOnly() async throws {
        let container = FakeContainer()
        let urls = Recorder()
        let search = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, urls: urls))
        #expect(container.starts == 0)

        let results = try await search.search("claude  max\nplan")
        #expect(results.count == 2)
        #expect(container.starts == 1)

        _ = try await search.search("again")
        #expect(container.starts == 1)

        // Searches go to this Mac only, as a properly encoded query.
        let searchURL = try #require(urls.all.first { $0.path == "/search" })
        #expect(searchURL.host == "127.0.0.1")
        #expect(searchURL.port == 18888)
        let items = URLComponents(url: searchURL, resolvingAgainstBaseURL: false)?.queryItems
        #expect(items == [URLQueryItem(name: "q", value: "claude max plan"), URLQueryItem(name: "format", value: "json")])
        #expect(urls.all.allSatisfy { $0.host == "127.0.0.1" })
    }

    @Test func everyCharacterInASearchIsSentAsTyped() throws {
        func terms(_ text: String) throws -> String? {
            let url = try #require(SearXNGSearch.searchURL(terms: text, port: 18888))
            #expect(url.host == "127.0.0.1")
            #expect(url.port == 18888)
            #expect(url.path == "/search")
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            #expect(items.map(\.name) == ["q", "format"])     // nothing can add a parameter
            #expect(items.last?.value == "json")
            return items.first?.value
        }
        // "+" used to arrive as a space, so "C++" searched for "C".
        #expect(try terms("C++ 1+1") == "C++ 1+1")
        #expect(SearXNGSearch.searchURL(terms: "C++", port: 18888)?.absoluteString.contains("C%2B%2B") == true)
        for tricky in ["a&format=html&b=c", "x#fragment", "50% off; now", "caf\u{00E9} \u{1F600}", "q=1?y=2", "//evil.example/@x"] {
            #expect(try terms(tricky) == tricky)
        }
    }

    @Test func quittingWhileTheContainerIsStartingStillStopsIt() async {
        let container = FakeContainer()
        container.becomesHealthy = false
        let search = SearXNGSearch(container: container, readyTimeout: 3, fetch: fetcher(container))
        let attempt = Task { try? await search.search("x") }
        #expect(await waitUntil { container.starts == 1 })
        await search.shutdown()
        #expect(container.stops == 1)
        attempt.cancel()
        _ = await attempt.value
    }

    @Test func anAlreadyRunningServiceIsNotStartedAgain() async throws {
        let container = FakeContainer()
        container.setRunning(true)
        let search = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container))
        _ = try await search.search("x")
        #expect(container.starts == 0)
    }

    @Test func stopsTheContainerAfterTheQuietPeriod() async throws {
        let container = FakeContainer()
        let search = SearXNGSearch(container: container, idleSeconds: 0.3, fetch: fetcher(container))
        _ = try await search.search("x")
        #expect(container.isRunning)
        #expect(await waitUntil(timeout: 3) { !container.isRunning })
        #expect(container.stops == 1)

        // The next search brings it back.
        _ = try await search.search("y")
        #expect(container.starts == 2)
        await search.shutdown()
    }

    @Test func aSearchDuringTheQuietPeriodKeepsItAlive() async throws {
        let container = FakeContainer()
        let search = SearXNGSearch(container: container, idleSeconds: 0.5, fetch: fetcher(container))
        _ = try await search.search("x")
        try await Task.sleep(nanoseconds: 300_000_000)
        _ = try await search.search("y")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(container.isRunning)   // 0.6 s after the first search, 0.3 s after the second
        #expect(container.stops == 0)
        await search.shutdown()
        #expect(container.stops == 1)
    }

    @Test func shutdownStopsWhatWasStartedAndIsHarmlessOtherwise() async throws {
        let unused = FakeContainer()
        await SearXNGSearch(container: unused, fetch: fetcher(unused)).shutdown()
        #expect(unused.stops == 0)

        let used = FakeContainer()
        let search = SearXNGSearch(container: used, idleSeconds: 60, fetch: fetcher(used))
        _ = try await search.search("x")
        await search.shutdown()
        await search.shutdown()
        #expect(used.stops == 1)
    }

    @Test func dockerProblemsReachTheCallerInWords() async {
        let container = FakeContainer()
        container.startError = .dockerNotRunning
        let search = SearXNGSearch(container: container, fetch: fetcher(container))
        await #expect(throws: WebSearchError.dockerNotRunning) { _ = try await search.search("x") }
        #expect(WebSearchError.dockerNotRunning.localizedDescription == "Docker is not running, so web search is unavailable")
    }

    @Test func aServiceThatNeverComesUpIsAnErrorNotAWait() async {
        let container = FakeContainer()
        container.becomesHealthy = false
        let search = SearXNGSearch(container: container, readyTimeout: 0.6, fetch: fetcher(container))
        let started = Date()
        await #expect(throws: WebSearchError.notReady) { _ = try await search.search("x") }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @Test func badRepliesFromTheServiceAreErrors() async {
        let container = FakeContainer()
        container.setRunning(true)
        let refused = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, status: 403))
        await #expect(throws: WebSearchError.failed("search service replied 403")) { _ = try await refused.search("x") }
        let garbage = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, body: Data("<html>".utf8)))
        await #expect(throws: WebSearchError.unreadable) { _ = try await garbage.search("x") }
    }

    @Test func enginesRefusingIsToldApartFromFindingNothing() async throws {
        let container = FakeContainer()
        container.setRunning(true)
        let refused = try JSONSerialization.data(withJSONObject: [
            "results": [], "unresponsive_engines": [["brave", "too many requests"], ["duckduckgo", "timeout"]],
        ])
        let blocked = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, body: refused))
        await #expect(throws: WebSearchError.enginesRefusing) { _ = try await blocked.search("x") }
        #expect(WebSearchError.enginesRefusing.localizedDescription.contains("try again in a few minutes"))

        // Some engines refusing while others answer is still a normal result.
        let partial = try JSONSerialization.data(withJSONObject: [
            "results": twoGood, "unresponsive_engines": [["brave", "too many requests"]],
        ])
        let working = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, body: partial))
        #expect(try await working.search("x").count == 2)

        // No results and nobody refusing means the search found nothing.
        let nothing = SearXNGSearch(container: container, idleSeconds: 0, fetch: fetcher(container, body: json([])))
        #expect(try await nothing.search("x").isEmpty)
    }

    @Test func anEmptySearchIsRefusedWithoutStartingAnything() async {
        let container = FakeContainer()
        let search = SearXNGSearch(container: container, fetch: fetcher(container))
        await #expect(throws: WebSearchError.failed("empty search")) { _ = try await search.search("  \n ") }
        #expect(container.starts == 0)
    }
}

final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    var all: [URL] { lock.withLock { urls } }
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
}
