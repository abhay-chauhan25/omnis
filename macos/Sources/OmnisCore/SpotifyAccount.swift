import CryptoKit
import Foundation
import Network
import Security

/// Something in Spotify's catalogue that can be played: a song, an album, an artist or a playlist.
public struct SpotifyItem: Equatable, Sendable {
    public enum Kind: String, Sendable, CaseIterable { case track, album, artist, playlist }
    public let kind: Kind
    /// Spotify's own identifier, 22 letters and digits.
    public let id: String
    public let name: String
    /// The artist, or the playlist's owner.
    public let by: String

    public init(kind: Kind, id: String, name: String, by: String) {
        self.kind = kind; self.id = id; self.name = name; self.by = by
    }

    /// The address Spotify's own app plays, or nil if the identifier is not what Spotify issues.
    public var uri: String? {
        guard id.count == 22, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { return nil }
        return "spotify:\(kind.rawValue):\(id)"
    }

    public var spoken: String { by.isEmpty ? name : (kind == .playlist ? "\(name), a playlist by \(by)" : "\(name) by \(by)") }
}

/// Looking things up in Spotify. Reading only: nothing here plays, saves or changes anything.
public protocol SpotifyCatalogue: Sendable {
    var isConnected: Bool { get }
    func search(_ query: String, kind: SpotifyItem.Kind) async throws -> [SpotifyItem]
    /// The user's own playlists.
    func playlists() async throws -> [SpotifyItem]
    /// Adds a song to what plays next. The one thing here that is not reading.
    func queue(_ item: SpotifyItem) async throws
    /// The address of the user's Liked Songs as one list, and the newest liked song as a fallback.
    func liked() async throws -> (list: String?, newest: SpotifyItem?)
}

/// The sign-in to Spotify's web service, kept in the Keychain.
struct SpotifyTokens: Codable, Equatable {
    var access: String
    var refresh: String
    var expires: Date
}

/// The steps of signing in to Spotify, with nothing in them that touches the network.
///
/// OMNIS has no secret of its own to keep: it proves it is the program that
/// began the sign-in by a one-time code only it knows (PKCE). It asks to read
/// the user's playlists and saved music, and to control playback, which is
/// needed for one thing: adding a song to what plays next. It cannot change,
/// save or delete anything in the user's library. Playing, pausing, volume
/// and the rest are done by the Spotify app on this Mac.
public enum SpotifyAuth {
    public static let port: UInt16 = 43_821
    public static let redirect = "http://127.0.0.1:43821/callback"
    public static let scopes = "playlist-read-private playlist-read-collaborative user-library-read user-modify-playback-state"

    /// A Spotify client ID is 32 hexadecimal characters.
    public static func isClientID(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { $0.isASCII && $0.isHexDigit }
    }

    public static func random(_ bytes: Int = 48) -> String {
        var data = Data(count: bytes)
        _ = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, bytes, $0.baseAddress!) }
        return base64URL(data)
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func challenge(for verifier: String) -> String {
        base64URL(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    public static func authorizeURL(clientID: String, state: String, verifier: String) -> URL {
        var parts = URLComponents(string: "https://accounts.spotify.com/authorize")!
        parts.queryItems = [
            URLQueryItem(name: "client_id", value: clientID), URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "redirect_uri", value: redirect), URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "scope", value: scopes), URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge(for: verifier)),
        ]
        return parts.url!
    }

    /// The code Spotify sent back, from the first line of the browser's request.
    /// Anything that does not carry the same `state` the sign-in began with is refused.
    public static func code(fromRequest line: String, state: String) throws -> String {
        let pieces = line.split(separator: " ")
        guard pieces.count >= 2, pieces[0] == "GET", let parts = URLComponents(string: "http://127.0.0.1" + pieces[1]),
              parts.path == "/callback" else { throw ToolRefusal("Spotify's reply was not understood") }
        let items = Dictionary((parts.queryItems ?? []).map { ($0.name, $0.value ?? "") }, uniquingKeysWith: { first, _ in first })
        guard items["state"] == state else { throw ToolRefusal("Spotify's reply did not match the sign-in that was started") }
        if let problem = items["error"] { throw ToolRefusal(problem == "access_denied" ? "the sign-in was cancelled" : "Spotify said: \(problem.prefix(60))") }
        guard let code = items["code"], !code.isEmpty, code.count < 2_000 else { throw ToolRefusal("Spotify sent no sign-in code") }
        return code
    }

    /// True when a request's first line carries the `state` of the sign-in that was started.
    static func carries(state: String, request line: String) -> Bool {
        let pieces = line.split(separator: " ")
        guard pieces.count >= 2, let parts = URLComponents(string: "http://127.0.0.1" + pieces[1]) else { return false }
        return parts.queryItems?.first { $0.name == "state" }?.value == state
    }

    static func form(_ fields: [String: String]) -> Data {
        var parts = URLComponents()
        parts.queryItems = fields.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        // A plus sign in a form means a space, so it is written out.
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

/// Waits on this Mac for the browser to come back from Spotify's sign-in page.
/// It listens only to this Mac itself, takes one request, and stops.
enum SpotifyCallback {
    /// `ready` is called once this Mac is listening, and not before: only then is the browser sent off.
    static func wait(state: String, seconds: Double = 180, ready: @escaping @Sendable () -> Void) async throws -> String {
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.acceptLocalOnly = true
        guard let port = NWEndpoint.Port(rawValue: SpotifyAuth.port), let listener = try? NWListener(using: parameters, on: port) else {
            throw ToolRefusal("the sign-in could not be started on this Mac")
        }
        let queue = DispatchQueue(label: "omnis.spotify.callback")
        let once = Once()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<String, Error>) in
            @Sendable func finish(_ result: Result<String, Error>) {
                guard once.take() else { return }
                listener.stateUpdateHandler = nil
                listener.newConnectionHandler = nil
                listener.cancel()
                continuation.resume(with: result)
            }
            listener.stateUpdateHandler = { state in
                if case .ready = state { ready() }
                if case .failed = state { finish(.failure(ToolRefusal("the sign-in could not be started on this Mac. Something else may be using its port"))) }
            }
            listener.newConnectionHandler = { connection in
                connection.start(queue: queue)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 8_192) { data, _, _, _ in
                    let line = data.flatMap { String(data: $0, encoding: .utf8) }?.components(separatedBy: "\r\n").first ?? ""
                    // A browser also asks for a page icon; only the callback itself is answered.
                    guard line.contains("/callback") else {
                        connection.send(content: Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    // Only the reply to the sign-in that was started ends the wait. Anything else that
                    // knocks on this door, such as another page in the browser, is turned away and the wait goes on.
                    guard SpotifyAuth.carries(state: state, request: line) else {
                        connection.send(content: Data("HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8),
                                        completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    let result = Result { try SpotifyAuth.code(fromRequest: line, state: state) }
                    let words: String
                    switch result {
                    case .success: words = "Spotify is connected to OMNIS. You can close this tab."
                    case .failure: words = "Spotify was not connected. You can close this tab and try again from OMNIS."
                    }
                    let page = "<!doctype html><meta charset=\"utf-8\"><title>OMNIS</title><body style=\"font:16px -apple-system;padding:48px\">\(words)</body>"
                    let reply = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
                    connection.send(content: Data(reply.utf8), completion: .contentProcessed { _ in
                        connection.cancel()
                        finish(result)
                    })
                }
            }
            listener.start(queue: queue)
            queue.asyncAfter(deadline: .now() + seconds) { finish(.failure(ToolRefusal("nobody finished the sign-in in time"))) }
        }
    }

    private final class Once: @unchecked Sendable {
        private let lock = NSLock()
        private var taken = false
        func take() -> Bool { lock.withLock { if taken { return false }; taken = true; return true } }
    }
}

/// The user's connection to Spotify's web service.
///
/// Spotify asks every such connection to belong to an "app" registered by a
/// developer. The user registers their own, once, and gives OMNIS its client
/// ID, which is not a secret. The sign-in itself is kept in the Keychain.
public final class SpotifyAccount: SpotifyCatalogue, @unchecked Sendable {
    public typealias Fetch = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let keychainService = "local.omnis.app.spotify"
    private static let clientKey = "OMNISSpotifyClientID"
    private let fetch: Fetch
    private let store: SecretStore
    private let defaults: UserDefaults
    private let lock = NSLock()
    private var tokens: SpotifyTokens?
    private var loaded = false
    private var signingIn = false

    public init(fetch: @escaping Fetch = { try await URLSession.shared.data(for: $0) }, store: SecretStore = KeychainStore(),
                defaults: UserDefaults = .standard) {
        self.fetch = fetch
        self.store = store
        self.defaults = defaults
    }

    /// The client ID given when Spotify was last connected, for connecting again without typing it.
    public var savedClientID: String? { clientID }

    private var clientID: String? {
        defaults.string(forKey: Self.clientKey).flatMap { SpotifyAuth.isClientID($0) ? $0 : nil }
    }

    private func current() -> SpotifyTokens? {
        lock.withLock {
            if !loaded {
                loaded = true
                tokens = store.read(service: Self.keychainService, account: "tokens").flatMap { try? JSONDecoder().decode(SpotifyTokens.self, from: $0) }
            }
            return tokens
        }
    }

    private func keep(_ fresh: SpotifyTokens?) {
        lock.withLock {
            loaded = true
            tokens = fresh
        }
        if let fresh, let data = try? JSONEncoder().encode(fresh) {
            store.write(data, service: Self.keychainService, account: "tokens")
        } else {
            store.delete(service: Self.keychainService, account: "tokens")
        }
    }

    public var isConnected: Bool { clientID != nil && current() != nil }

    /// Forgets the sign-in on this Mac.
    public func disconnect() {
        keep(nil)
        defaults.removeObject(forKey: Self.clientKey)
    }

    /// Signs in through the user's browser. `open` is given Spotify's sign-in page to show.
    public func connect(clientID: String, open: @escaping @Sendable (URL) -> Void) async throws {
        guard SpotifyAuth.isClientID(clientID) else { throw ToolRefusal("that is not a Spotify client ID, which is 32 letters and digits") }
        let busy = lock.withLock { () -> Bool in
            if signingIn { return true }
            signingIn = true
            return false
        }
        guard !busy else { throw ToolRefusal("a Spotify sign-in is already open in your browser") }
        defer { lock.withLock { signingIn = false } }
        let state = SpotifyAuth.random(24), verifier = SpotifyAuth.random()
        let page = SpotifyAuth.authorizeURL(clientID: clientID, state: state, verifier: verifier)
        // The browser is sent to Spotify only once this Mac is ready for it to come back.
        let code = try await SpotifyCallback.wait(state: state, ready: { open(page) })
        let fresh: SpotifyTokens
        do {
            fresh = try await token(["grant_type": "authorization_code", "code": code, "redirect_uri": SpotifyAuth.redirect,
                                     "client_id": clientID, "code_verifier": verifier], keeping: nil)
        } catch is SignInRejected {
            throw ToolRefusal("Spotify did not accept the sign-in. Check the client ID and the redirect address in your Spotify app")
        }
        defaults.set(clientID, forKey: Self.clientKey)
        keep(fresh)
    }

    private func token(_ fields: [String: String], keeping refresh: String?) async throws -> SpotifyTokens {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = SpotifyAuth.form(fields)
        request.timeoutInterval = 15
        let (data, response) = try await fetch(request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let object = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        // Only Spotify saying the sign-in itself is no good counts as that. Being busy or unreachable does not.
        if status == 400 || status == 401, ["invalid_grant", "invalid_client"].contains(object["error"] as? String ?? "") { throw SignInRejected() }
        guard status == 200, let access = object["access_token"] as? String, let kept = object["refresh_token"] as? String ?? refresh else {
            throw ToolRefusal("Spotify did not answer the sign-in; try again in a moment")
        }
        let seconds = (object["expires_in"] as? Double) ?? 3_600
        return SpotifyTokens(access: access, refresh: kept, expires: Date().addingTimeInterval(seconds - 60))
    }

    private struct SignInRejected: Error {}
    private var renewing: Task<String, Error>?

    private func access() async throws -> String {
        guard let clientID, let now = current() else { throw ToolRefusal(Self.notConnected) }
        if now.expires > Date() { return now.access }
        // One renewal at a time: Spotify may replace the long-lived half, and a second request with the old one would fail.
        let renewal = lock.withLock { () -> Task<String, Error> in
            if let renewing { return renewing }
            let fresh = Task { [weak self] () throws -> String in
                guard let self else { throw CancellationError() }
                defer { self.lock.withLock { self.renewing = nil } }
                do {
                    let tokens = try await self.token(["grant_type": "refresh_token", "refresh_token": now.refresh, "client_id": clientID], keeping: now.refresh)
                    self.keep(tokens)
                    return tokens.access
                } catch is SignInRejected {
                    // Spotify no longer accepts the sign-in: it has to be done again.
                    self.keep(nil)
                    throw ToolRefusal("Spotify no longer accepts the sign-in. It needs connecting again: type /spotify")
                }
            }
            renewing = fresh
            return fresh
        }
        return try await renewal.value
    }

    public static let notConnected = "Spotify's catalogue is not connected to OMNIS"

    private func request(_ method: String, _ path: String, _ query: [String: String]) async throws -> (Int, Data) {
        var parts = URLComponents(string: "https://api.spotify.com/v1/\(path)")!
        parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        var request = URLRequest(url: parts.url!)
        request.httpMethod = method
        request.setValue("Bearer \(try await access())", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 12
        let (data, response) = try await fetch(request)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }

    public func queue(_ item: SpotifyItem) async throws {
        guard item.kind == .track, let uri = item.uri else { throw ToolRefusal("only a song can be added to what plays next") }
        let (status, data) = try await request("POST", "me/player/queue", ["uri": uri])
        guard !(200..<300).contains(status) else { return }
        let reason = ((try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? [String: Any])?["reason"] as? String
        throw ToolRefusal(status == 404 || reason == "NO_ACTIVE_DEVICE" ? "Spotify has nothing playing to queue after. Play something first"
                          : status == 401 || status == 403 ? "Spotify has not given OMNIS permission to queue songs. Tell the user to type /spotify reconnect in OMNIS, once"
                          : status == 429 ? "Spotify is asking OMNIS to slow down; try again in a minute" : "Spotify did not add it")
    }

    public func liked() async throws -> (list: String?, newest: SpotifyItem?) {
        // The list's address is made from the account's name, which only Spotify supplies.
        let name = (try? await get("me", [:]))?["id"] as? String ?? ""
        let safe = !name.isEmpty && name.count <= 64 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "._-".contains($0)) }
        let saved = try await get("me/tracks", ["limit": "1"])
        let newest = ((saved["items"] as? [[String: Any]]) ?? []).first.flatMap { Self.item($0["track"], kind: .track) }
        return (safe ? "spotify:user:\(name):collection" : nil, newest)
    }

    private func get(_ path: String, _ query: [String: String]) async throws -> [String: Any] {
        let (status, data) = try await request("GET", path, query)
        guard status == 200, let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ToolRefusal(status == 429 ? "Spotify is asking OMNIS to slow down; try again in a minute"
                              : status == 401 || status == 403 ? "Spotify refused the request. It may need connecting again, and it needs a Premium account"
                              : "Spotify did not answer")
        }
        return object
    }

    static func item(_ raw: Any?, kind: SpotifyItem.Kind) -> SpotifyItem? {
        guard let object = raw as? [String: Any], let id = object["id"] as? String, let name = object["name"] as? String else { return nil }
        let by: String
        switch kind {
        case .track, .album:
            by = ((object["artists"] as? [[String: Any]]) ?? []).compactMap { $0["name"] as? String }.prefix(2).joined(separator: " and ")
        case .playlist:
            by = ((object["owner"] as? [String: Any])?["display_name"] as? String) ?? ""
        case .artist:
            by = ""
        }
        let found = SpotifyItem(kind: kind, id: id, name: CalendarFormatter.clean(name), by: CalendarFormatter.clean(by))
        return found.uri == nil ? nil : found
    }

    public func search(_ query: String, kind: SpotifyItem.Kind) async throws -> [SpotifyItem] {
        let object = try await get("search", ["q": query, "type": kind.rawValue, "limit": "5"])
        let found = ((object["\(kind.rawValue)s"] as? [String: Any])?["items"] as? [Any]) ?? []
        return found.compactMap { Self.item($0, kind: kind) }
    }

    public func playlists() async throws -> [SpotifyItem] {
        let object = try await get("me/playlists", ["limit": "50"])
        return ((object["items"] as? [Any]) ?? []).compactMap { Self.item($0, kind: .playlist) }
    }
}

/// Where a secret is kept. The real one is the macOS Keychain.
public protocol SecretStore: Sendable {
    func read(service: String, account: String) -> Data?
    func write(_ data: Data, service: String, account: String)
    func delete(service: String, account: String)
}

public struct KeychainStore: SecretStore {
    public init() {}

    private func query(_ service: String, _ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func read(service: String, account: String) -> Data? {
        var wanted = query(service, account)
        wanted[kSecReturnData as String] = true
        wanted[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        return SecItemCopyMatching(wanted as CFDictionary, &found) == errSecSuccess ? found as? Data : nil
    }

    public func write(_ data: Data, service: String, account: String) {
        let base = query(service, account)
        if SecItemUpdate(base as CFDictionary, [kSecValueData as String: data] as CFDictionary) == errSecItemNotFound {
            var fresh = base
            fresh[kSecValueData as String] = data
            fresh[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(fresh as CFDictionary, nil)
        }
    }

    public func delete(service: String, account: String) {
        SecItemDelete(query(service, account) as CFDictionary)
    }
}
