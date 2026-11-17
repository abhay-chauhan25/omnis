import Foundation

/// One web search result as shown to the model and to the user.
public struct SearchResult: Equatable, Sendable, Identifiable {
    public let title: String
    public let url: URL
    public let snippet: String

    public var id: String { url.absoluteString }
    /// The site name, for display ("support.claude.com").
    public var host: String { url.host ?? url.absoluteString }

    public init(title: String, url: URL, snippet: String) {
        self.title = title
        self.url = url
        self.snippet = snippet
    }
}

public enum WebSearchError: Error, Equatable, LocalizedError {
    case dockerMissing
    case dockerNotRunning
    case startFailed(String)
    case notReady
    case unreadable
    /// Every search engine behind the service refused or timed out.
    case enginesRefusing
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .dockerMissing: return "Docker is not installed, so web search is unavailable"
        case .dockerNotRunning: return "Docker is not running, so web search is unavailable"
        case .startFailed(let why): return "the search service could not start (\(why))"
        case .notReady: return "the search service did not become ready in time"
        case .unreadable: return "the search service sent an unreadable reply"
        case .enginesRefusing: return "the search engines are refusing requests for now; try again in a few minutes"
        case .failed(let why): return "the search failed (\(why))"
        }
    }
}

/// Anything that can run a web search for OMNIS.
public protocol WebSearching: Sendable {
    func search(_ query: String) async throws -> [SearchResult]
    /// Stop anything the searcher started. Safe to call when nothing is running.
    func shutdown() async
}

// MARK: - Reading SearXNG results

public enum SearXNGResults {
    public static let maxResults = 6
    static let maxTitle = 200
    static let maxSnippet = 500
    static let maxURL = 2000

    /// Reads SearXNG's JSON. Only `https` results with a title are kept, so
    /// nothing the user can click leads anywhere but a normal web page.
    public static func parse(_ data: Data) throws -> [SearchResult] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let raw = object["results"] as? [Any] else {
            throw WebSearchError.unreadable
        }
        var results: [SearchResult] = []
        var seen = Set<String>()
        for item in raw {
            guard results.count < maxResults else { break }
            guard let entry = item as? [String: Any],
                  let address = entry["url"] as? String, address.count <= maxURL,
                  let url = URL(string: address),
                  url.scheme?.lowercased() == "https",
                  let host = url.host, !host.isEmpty,
                  url.user == nil, url.password == nil else { continue }
            let title = clean(entry["title"] as? String ?? "", limit: maxTitle)
            guard !title.isEmpty, seen.insert(url.absoluteString).inserted else { continue }
            let snippet = clean(entry["content"] as? String ?? "", limit: maxSnippet)
            results.append(SearchResult(title: title, url: url, snippet: snippet))
        }
        return results
    }

    /// True if the reply says engines refused or timed out. With no results,
    /// that means the search did not really run, as opposed to finding nothing.
    public static func enginesRefused(_ data: Data) -> Bool {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let refused = object["unresponsive_engines"] as? [Any] else { return false }
        return !refused.isEmpty
    }

    /// Collapses whitespace and removes control characters, then trims to a limit.
    static func clean(_ text: String, limit: Int) -> String {
        let scalars = text.unicodeScalars.map { scalar -> Character in
            CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
        }
        let collapsed = String(scalars).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(limit))
    }
}

// MARK: - The container

/// Starts and stops the search container.
public protocol ContainerControlling: Sendable {
    func start() async throws
    func stop() async
}

/// Runs SearXNG in Docker, reachable only from this Mac.
public struct SearXNGContainer: ContainerControlling {
    public static let name = "omnis-searxng"
    public static let image = "searxng/searxng:latest"

    public let docker: URL
    public let settingsDirectory: URL
    public let port: Int

    public init(docker: URL, settingsDirectory: URL, port: Int = SearXNGSearch.defaultPort) {
        self.docker = docker
        self.settingsDirectory = settingsDirectory
        self.port = port
    }

    /// The exact program arguments. No shell is involved, and the published
    /// port is bound to the loopback address only.
    public var startArguments: [String] {
        [
            "run", "--detach", "--rm",
            "--name", Self.name,
            "--publish", "127.0.0.1:\(port):8080",
            "--volume", "\(settingsDirectory.path):/etc/searxng",
            Self.image,
        ]
    }

    public var stopArguments: [String] { ["stop", "--time", "2", Self.name] }

    public func start() async throws {
        guard FileManager.default.isExecutableFile(atPath: docker.path) else { throw WebSearchError.dockerMissing }
        try Self.writeSettingsIfNeeded(in: settingsDirectory)
        let outcome = await Self.run(docker, startArguments)
        guard outcome.status != 0 else { return }
        let detail = outcome.errorText.lowercased()
        if detail.contains("cannot connect to the docker daemon") || detail.contains("is the docker daemon running") {
            throw WebSearchError.dockerNotRunning
        }
        // Our own container left over from an earlier run is fine to reuse.
        if detail.contains("is already in use") { return }
        throw WebSearchError.startFailed(String(outcome.errorText.prefix(160)))
    }

    public func stop() async {
        guard FileManager.default.isExecutableFile(atPath: docker.path) else { return }
        _ = await Self.run(docker, stopArguments)
    }

    /// For use while the app is quitting, when nothing can be awaited.
    public func stopNow() {
        guard FileManager.default.isExecutableFile(atPath: docker.path) else { return }
        let process = Process()
        process.executableURL = docker
        process.arguments = stopArguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return }
        process.waitUntilExit()
    }

    /// Bumped whenever the settings below change, so an older file is replaced.
    static let settingsVersion = 2
    static var settingsMarker: String { "# omnis-settings: \(settingsVersion)" }

    /// The extra engines switched on beside SearXNG's defaults. Several are
    /// used so that one engine refusing requests does not leave a search
    /// with no results. Search terms go to each of them.
    public static let extraEngines = ["bing", "yahoo", "mojeek", "startpage", "wikipedia"]

    /// SearXNG needs a settings file: machine-readable output is off by
    /// default, and it wants a secret key of its own. The file is written if
    /// it is missing or was written by an older version of OMNIS.
    public static func writeSettingsIfNeeded(in directory: URL) throws {
        let fileManager = FileManager.default
        let file = directory.appendingPathComponent("settings.yml")
        if let existing = try? String(contentsOf: file, encoding: .utf8), existing.contains(settingsMarker) {
            return
        }
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        let secret = (0..<4).map { _ in UUID().uuidString.replacingOccurrences(of: "-", with: "") }.joined().lowercased()
        let engines = extraEngines.map { "  - name: \($0)\n    disabled: false" }.joined(separator: "\n")
        let settings = """
        # SearXNG settings for OMNIS. Reached only from this Mac.
        \(settingsMarker)
        use_default_settings: true
        server:
          secret_key: "\(secret)"
          limiter: false
          image_proxy: false
        search:
          safe_search: 1
          formats:
            - html
            - json
        engines:
        \(engines)

        """
        try settings.write(to: file, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private static func run(_ program: URL, _ arguments: [String]) async -> (status: Int32, errorText: String) {
        await withCheckedContinuation { continuation in
            let process = Process()
            let errors = Pipe()
            process.executableURL = program
            process.arguments = arguments
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errors
            process.terminationHandler = { finished in
                let data = ((try? errors.fileHandleForReading.readToEnd()) ?? nil) ?? Data()
                continuation.resume(returning: (finished.terminationStatus, String(decoding: data, as: UTF8.self)))
            }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(returning: (-1, error.localizedDescription))
            }
        }
    }
}

// MARK: - The searcher

/// Web search through a SearXNG container that runs only around searches:
/// started on the first one, stopped after a quiet period.
public actor SearXNGSearch: WebSearching {
    public static let defaultPort = 18888

    /// Fetches a URL and returns the body and HTTP status. Injected so tests need no network.
    public typealias Fetch = @Sendable (URL) async throws -> (Data, Int)

    private let container: ContainerControlling
    private let port: Int
    private let idleSeconds: Double
    private let readyTimeout: Double
    private let fetch: Fetch
    private var lastUse = Date.distantPast
    private var idleTask: Task<Void, Never>?
    private var mayBeRunning = false

    public init(
        container: ContainerControlling,
        port: Int = SearXNGSearch.defaultPort,
        idleSeconds: Double = 300,
        readyTimeout: Double = 25,
        fetch: Fetch? = nil
    ) {
        self.container = container
        self.port = port
        self.idleSeconds = idleSeconds
        self.readyTimeout = readyTimeout
        self.fetch = fetch ?? Self.loopbackFetch
    }

    public func search(_ query: String) async throws -> [SearchResult] {
        let terms = SearXNGResults.clean(query, limit: 200)
        guard !terms.isEmpty else { throw WebSearchError.failed("empty search") }

        if !(await isHealthy()) {
            try await container.start()
            mayBeRunning = true
            try await waitUntilHealthy()
        }
        mayBeRunning = true
        lastUse = Date()
        scheduleIdleStop()

        var components = URLComponents()
        components.scheme = "http"
        components.host = "127.0.0.1"
        components.port = port
        components.path = "/search"
        components.queryItems = [URLQueryItem(name: "q", value: terms), URLQueryItem(name: "format", value: "json")]
        guard let url = components.url else { throw WebSearchError.failed("bad search address") }

        let data: Data
        let status: Int
        do {
            (data, status) = try await fetch(url)
        } catch {
            throw WebSearchError.failed("no reply from the search service")
        }
        guard status == 200 else { throw WebSearchError.failed("search service replied \(status)") }
        let results = try SearXNGResults.parse(data)
        if results.isEmpty && SearXNGResults.enginesRefused(data) { throw WebSearchError.enginesRefusing }
        return results
    }

    public func shutdown() async {
        idleTask?.cancel()
        idleTask = nil
        guard mayBeRunning else { return }
        mayBeRunning = false
        await container.stop()
    }

    private func isHealthy() async -> Bool {
        guard let url = URL(string: "http://127.0.0.1:\(port)/healthz") else { return false }
        guard let (_, status) = try? await fetch(url) else { return false }
        return status == 200
    }

    private func waitUntilHealthy() async throws {
        let deadline = Date().addingTimeInterval(readyTimeout)
        while Date() < deadline {
            if await isHealthy() { return }
            try? await Task.sleep(nanoseconds: 250_000_000)
        }
        throw WebSearchError.notReady
    }

    private func scheduleIdleStop() {
        idleTask?.cancel()
        guard idleSeconds > 0 else { return }
        let wait = idleSeconds
        idleTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.stopIfIdle()
        }
    }

    private func stopIfIdle() async {
        guard mayBeRunning, Date().timeIntervalSince(lastUse) >= idleSeconds * 0.95 else { return }
        mayBeRunning = false
        await container.stop()
    }

    /// Plain HTTP is used only to reach this Mac's own loopback address.
    private static let loopbackFetch: Fetch = { url in
        guard url.host == "127.0.0.1" else { throw WebSearchError.failed("refused a non-local address") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpCookieStorage = nil
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}
