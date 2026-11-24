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

    public init(socketPath: String, databasePath: String, callerRequirement: String, idleSeconds: Double = 120) {
        self.socketPath = socketPath
        self.databasePath = databasePath
        self.callerRequirement = callerRequirement
        self.idleSeconds = idleSeconds
    }

    /// Serves until nothing has been asked for `idleSeconds`. Returns false if it could not start.
    @discardableResult
    public func run() -> Bool {
        let folder = (socketPath as NSString).deletingLastPathComponent
        try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let listener = try? LocalSocket.listen(at: socketPath) else { return false }
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
            serve(connection)
            close(connection)
            lastAsked = Date()
        }
        return true
    }

    private func send(_ reply: ReaderReply, to connection: Int32) {
        if let data = try? JSONEncoder().encode(reply) { LocalSocket.writeLine(connection, data) }
    }

    private func serve(_ connection: Int32) {
        // First, and before a single byte is read: who is asking?
        guard PeerCheck.peer(of: connection, satisfies: callerRequirement) else {
            send(ReaderReply(ok: false, code: "not_recognised"), to: connection)
            return
        }
        guard let line = LocalSocket.readLine(connection, limit: 16_384),
              let request = try? JSONDecoder().decode(ReaderRequest.self, from: line) else {
            send(ReaderReply(ok: false, code: "bad_request"), to: connection)
            return
        }
        send(Self.answer(request, databasePath: databasePath), to: connection)
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
