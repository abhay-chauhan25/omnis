import Foundation
import OmnisHelperLink

public enum ReaderProblem: Error, Equatable, LocalizedError {
    /// The helper was not built, usually because OMNIS has no stable signature.
    case notInstalled
    case couldNotStart
    /// Something else is answering at the helper's address. It is not talked to.
    case impostor
    /// The helper has not been given Full Disk Access.
    case noAccess
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInstalled: return "the Messages reader is not set up on this Mac"
        case .couldNotStart: return "the Messages reader could not be started"
        case .impostor: return "something other than the Messages reader answered, so nothing was asked of it"
        case .noAccess:
            return "the Messages reader has not been allowed to read messages. In System Settings, under Privacy & Security, Full Disk Access, switch on OMNIS Messages Reader"
        case .failed(let why): return "the Messages reader could not answer (\(why))"
        }
    }
}

/// OMNIS's side of the conversation with its Messages reader.
///
/// The reader is a separate program so that it, and not OMNIS, holds the
/// permission to read messages. It is started through macOS's own launcher,
/// which makes macOS treat it as its own program rather than as part of OMNIS.
public struct MessagesReaderClient: Sendable {
    public var helper: URL
    public var socketPath: String
    /// What the program answering must be signed as.
    public var helperRequirement: String
    public var launcher: URL = URL(fileURLWithPath: "/usr/bin/open")

    public init(helper: URL, socketPath: String, helperRequirement: String) {
        self.helper = helper
        self.socketPath = socketPath
        self.helperRequirement = helperRequirement
    }

    public static var standardSocket: String {
        OmnisPaths.supportDirectory.appendingPathComponent("helper/messages.sock").path
    }

    private func connect() throws -> Int32 {
        if let descriptor = try? LocalSocket.connect(to: socketPath) { return descriptor }
        guard FileManager.default.fileExists(atPath: helper.path) else { throw ReaderProblem.notInstalled }
        let start = Process()
        start.executableURL = launcher
        // In the background, with no window and nothing brought to the front.
        start.arguments = ["-g", "-j", helper.path]
        start.standardOutput = FileHandle.nullDevice
        start.standardError = FileHandle.nullDevice
        do { try start.run() } catch { throw ReaderProblem.couldNotStart }
        start.waitUntilExit()
        for _ in 0..<150 {
            if let descriptor = try? LocalSocket.connect(to: socketPath) { return descriptor }
            usleep(20_000)
        }
        throw ReaderProblem.couldNotStart
    }

    /// Asks one question. Blocks for up to about twenty seconds, so call it off the main thread.
    public func ask(_ request: ReaderRequest) throws -> ReaderReply {
        let descriptor = try connect()
        defer { close(descriptor) }
        // Before anything is sent or believed: is this really the reader?
        guard PeerCheck.isPinned(helperRequirement, to: "local.omnis.messages-reader"),
              PeerCheck.peer(of: descriptor, satisfies: helperRequirement, hardened: true) else { throw ReaderProblem.impostor }
        guard let body = try? JSONEncoder().encode(request), LocalSocket.writeLine(descriptor, body),
              let line = LocalSocket.readLine(descriptor), let reply = try? JSONDecoder().decode(ReaderReply.self, from: line) else {
            throw ReaderProblem.failed("no reply")
        }
        guard reply.ok else {
            switch reply.code {
            case "no_access": throw ReaderProblem.noAccess
            case "not_recognised": throw ReaderProblem.failed("it did not recognise this copy of OMNIS")
            default: throw ReaderProblem.failed(reply.code ?? "unknown")
            }
        }
        return reply
    }
}
