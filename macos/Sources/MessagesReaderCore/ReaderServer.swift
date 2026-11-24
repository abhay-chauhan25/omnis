import Foundation
import OmnisHelperLink

/// Answers OMNIS's questions about messages, one per connection. It answers
/// nobody else: before reading anything it checks, with the system, that the
/// program connecting is OMNIS as signed on this Mac.
public final class ReaderServer {
    private let socketPath: String
    private let databasePath: String
    private let callerRequirement: String
    private let idleSeconds: Double
    private let requireHardenedCaller: Bool
    private let logPath: String?

    /// `logPath` is where a line is written for every request and every
    /// refused caller: what was asked for and how much came back, never whose
    /// messages or which words.
    public init(socketPath: String, databasePath: String, callerRequirement: String, idleSeconds: Double = 120,
                requireHardenedCaller: Bool = false, logPath: String? = nil) {
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.callerRequirement = callerRequirement
        self.idleSeconds = idleSeconds
        self.requireHardenedCaller = requireHardenedCaller
        self.logPath = logPath
    }

    private func log(_ fields: [String: Any]) {
        guard let logPath else { return }
        var entry = fields
        entry["time"] = ISO8601DateFormatter().string(from: Date())
        guard var line = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
        line.append(0x0A)
        if !FileManager.default.fileExists(atPath: logPath) {
            FileManager.default.createFile(atPath: logPath, contents: nil, attributes: [.posixPermissions: 0o600])
        }
        guard let handle = FileHandle(forWritingAtPath: logPath) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: line)
    }

    /// The folder must be a real folder of this user's that nobody else can open: not a link to somewhere else.
    static func folderIsSafe(_ path: String) -> Bool {
        var details = stat()
        guard lstat(path, &details) == 0 else { return false }
        return details.st_mode & S_IFMT == S_IFDIR && details.st_uid == getuid() && details.st_mode & 0o077 == 0
    }

    /// Serves until nothing has been asked for `idleSeconds`. Returns false if it could not start.
    @discardableResult
    public func run() -> Bool {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard Self.folderIsSafe(folder), let listener = try? LocalSocket.listen(at: socketPath) else { return false }
        defer {
            close(listener)
            unlink(socketPath)
        }
        var lastAsked = Date()
        while Date().timeIntervalSince(lastAsked) < idleSeconds {
            var waiting = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard poll(&waiting, 1, 1000) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            LocalSocket.prepare(connection, seconds: 5)
            // Only a caller that was recognised keeps the reader running.
            if serve(connection) { lastAsked = Date() }
            close(connection)
        }
        return true
    }

    private func send(_ reply: ReaderReply, to connection: Int32) {
        if let data = try? JSONEncoder().encode(reply) { LocalSocket.writeLine(connection, data) }
    }

    /// Returns true if the caller was recognised.
    private func serve(_ connection: Int32) -> Bool {
        // First, and before a single byte is read: who is asking?
        guard PeerCheck.peer(of: connection, satisfies: callerRequirement, hardened: requireHardenedCaller) else {
            log(["event": "refused_caller"])
            send(ReaderReply(ok: false, code: "not_recognised"), to: connection)
            return false
        }
        // The whole request must arrive within a few seconds, however slowly it is sent.
        guard let line = LocalSocket.readLine(connection, limit: 16_384, deadline: Date().addingTimeInterval(6)),
              let request = try? JSONDecoder().decode(ReaderRequest.self, from: line) else {
            log(["event": "request", "op": "unreadable", "outcome": "bad_request"])
            send(ReaderReply(ok: false, code: "bad_request"), to: connection)
            return true
        }
        let reply = Self.answer(request, databasePath: databasePath)
        let known = ["status", "chats", "messages", "search"].contains(request.op) ? request.op : "unknown"
        log(["event": "request", "op": known, "outcome": reply.ok ? "ok" : (reply.code ?? "failed"),
             "chats": reply.chats?.count ?? 0, "messages": reply.messages?.count ?? 0])
        send(reply, to: connection)
        return true
    }

    /// The whole of what this program can be asked to do.
    public static func answer(_ request: ReaderRequest, databasePath: String, now: Date = Date()) -> ReaderReply {
        do {
            let store = try MessageStore(path: databasePath)
            let days = request.days ?? 30
            let limit = request.limit ?? 30
            switch request.op {
            case "status":
                return ReaderReply(ok: true)
            case "chats":
                return ReaderReply(ok: true, chats: try store.chats(limit: limit))
            case "messages":
                guard let chat = request.chat, !chat.isEmpty, chat.count <= 200 else { return ReaderReply(ok: false, code: "bad_request") }
                return ReaderReply(ok: true, messages: try store.messages(chat: chat, days: days, limit: limit, now: now))
            case "search":
                guard let text = request.text, !text.isEmpty, text.count <= 200 else { return ReaderReply(ok: false, code: "bad_request") }
                return ReaderReply(ok: true, messages: try store.search(text: text, days: days, limit: limit, now: now))
            default:
                return ReaderReply(ok: false, code: "bad_request")
            }
        } catch StoreError.noAccess {
            return ReaderReply(ok: false, code: "no_access")
        } catch {
            return ReaderReply(ok: false, code: "failed")
        }
    }
}
