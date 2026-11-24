import Foundation
import Security

/// What OMNIS and its Messages reader say to each other. One JSON object per
/// connection each way, over a socket only this user can reach.
public struct ReaderRequest: Codable, Equatable, Sendable {
    /// "status", "chats", "messages" or "search".
    public var op: String
    /// Which conversation, as named in a "chats" reply.
    public var chat: String?
    /// Words to look for.
    public var text: String?
    /// How far back to look, in days.
    public var days: Int?
    public var limit: Int?

    public init(op: String, chat: String? = nil, text: String? = nil, days: Int? = nil, limit: Int? = nil) {
        self.op = op
        self.chat = chat
        self.text = text
        self.days = days
        self.limit = limit
    }
}

public struct ReaderChat: Codable, Equatable, Sendable {
    /// The conversation's identifier: a phone number or address for one person, a code for a group.
    public var id: String
    /// The name the user gave a group, if any.
    public var name: String
    public var group: Bool
    /// Phone numbers and addresses of the other people in it.
    public var people: [String]
    /// When the latest message was, in seconds since 1970.
    public var last: Double

    public init(id: String, name: String = "", group: Bool = false, people: [String] = [], last: Double = 0) {
        self.id = id
        self.name = name
        self.group = group
        self.people = people
        self.last = last
    }
}

public struct ReaderMessage: Codable, Equatable, Sendable {
    public var chat: String
    public var time: Double
    public var fromMe: Bool
    /// Who sent it, as a phone number or address. Empty for the user's own.
    public var sender: String
    public var text: String

    public init(chat: String, time: Double, fromMe: Bool, sender: String, text: String) {
        self.chat = chat
        self.time = time
        self.fromMe = fromMe
        self.sender = sender
        self.text = text
    }
}

public struct ReaderReply: Codable, Equatable, Sendable {
    public var ok: Bool
    /// A short code when not ok: "no_access", "not_recognised", "bad_request", "failed".
    public var code: String?
    public var chats: [ReaderChat]?
    public var messages: [ReaderMessage]?

    public init(ok: Bool, code: String? = nil, chats: [ReaderChat]? = nil, messages: [ReaderMessage]? = nil) {
        self.ok = ok
        self.code = code
        self.chats = chats
        self.messages = messages
    }
}

/// Finds out which program is at the other end of a socket, from the kernel,
/// and checks its code signature. A program cannot lie about this: the token
/// names the running process itself, not a path or a number that can be reused.
public enum PeerCheck {
    public static func token(of descriptor: Int32) -> Data? {
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        // SOL_LOCAL is 0 and LOCAL_PEERTOKEN is 6 in <sys/un.h>.
        guard getsockopt(descriptor, 0, 0x006, &token, &length) == 0, Int(length) == MemoryLayout<audit_token_t>.size else { return nil }
        return withUnsafeBytes(of: &token) { Data($0) }
    }

    /// True only if the program at the other end is validly signed and meets
    /// the requirement, written in Apple's code-requirement language.
    /// With `hardened`, the program must also have been built so that no other
    /// code can be loaded into it, and must not carry a setting that undoes that.
    public static func peer(of descriptor: Int32, satisfies requirement: String, hardened: Bool = false) -> Bool {
        guard let token = token(of: descriptor) else { return false }
        var code: SecCode?
        let attributes = [kSecGuestAttributeAudit: token] as CFDictionary
        guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &code) == errSecSuccess, let code else { return false }
        var wanted: SecRequirement?
        guard SecRequirementCreateWithString(requirement as CFString, [], &wanted) == errSecSuccess, let wanted else { return false }
        guard SecCodeCheckValidity(code, [], wanted) == errSecSuccess else { return false }
        return hardened ? isHardened(code) : true
    }

    /// True if the running program was signed with the hardened runtime and
    /// without any of the settings that let other code into it.
    static func isHardened(_ code: SecCode) -> Bool {
        var onDisk: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &onDisk) == errSecSuccess, let onDisk else { return false }
        var details: CFDictionary?
        guard SecCodeCopySigningInformation(onDisk, SecCSFlags(rawValue: kSecCSSigningInformation), &details) == errSecSuccess,
              let information = details as? [String: Any],
              let flags = (information[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value else { return false }
        // 0x10000 is the hardened runtime.
        guard flags & 0x10000 != 0 else { return false }
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        let loosening = ["com.apple.security.get-task-allow", "com.apple.security.cs.allow-dyld-environment-variables",
                         "com.apple.security.cs.disable-library-validation", "com.apple.security.cs.allow-unsigned-executable-memory",
                         "com.apple.security.cs.disable-executable-page-protection", "com.apple.security.cs.debugger"]
        return !loosening.contains { entitlements[$0] as? Bool == true }
    }

    /// True if this program itself is still the one that was signed: nothing
    /// in it, including its settings file, has been altered since.
    public static func ownSignatureIsIntact() -> Bool {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return false }
        return SecCodeCheckValidity(code, [], nil) == errSecSuccess
    }

    /// A requirement of exactly the one shape OMNIS uses: this name, signed
    /// with this certificate. Anything looser, such as one with "or" in it, is not accepted.
    public static func isPinned(_ requirement: String, to identifier: String) -> Bool {
        let prefix = "identifier \"\(identifier)\" and certificate leaf = H\""
        guard requirement.hasPrefix(prefix), requirement.hasSuffix("\"") else { return false }
        let hash = requirement.dropFirst(prefix.count).dropLast()
        return hash.count == 40 && hash.allSatisfy { "0123456789abcdef".contains($0) }
    }
}

public enum SocketError: Error, Equatable {
    case pathTooLong
    case failed(String)
}

/// Small helpers for a Unix socket that carries one line each way.
public enum LocalSocket {
    public static let maxLine = 1_500_000

    private static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw SocketError.pathTooLong }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: bytes)
            buffer[bytes.count] = 0
        }
        return address
    }

    /// Starts listening at `path`, replacing anything already there. Only this user can connect.
    public static func listen(at path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.failed("socket") }
        unlink(path)
        let old = umask(0o177)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        umask(old)
        guard bound == 0, Darwin.listen(descriptor, 4) == 0 else {
            close(descriptor)
            throw SocketError.failed("bind")
        }
        return descriptor
    }

    public static func connect(to path: String) throws -> Int32 {
        var address = try address(path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw SocketError.failed("socket") }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else {
            close(descriptor)
            throw SocketError.failed("connect")
        }
        prepare(descriptor)
        return descriptor
    }

    /// Reads and writes give up after `seconds`, and a closed far end is an error, not a crash.
    public static func prepare(_ descriptor: Int32, seconds: Int = 20) {
        var wait = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &wait, socklen_t(MemoryLayout<timeval>.size))
        var on: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// One line, without its newline, or nil if the far end closed, was too slow or sent too much.
    public static func readLine(_ descriptor: Int32, limit: Int = maxLine, deadline: Date? = nil) -> Data? {
        var line = Data()
        var chunk = [UInt8](repeating: 0, count: 16_384)
        while line.count <= limit {
            if let deadline, Date() > deadline { return nil }
            let count = read(descriptor, &chunk, chunk.count)
            guard count > 0 else { return nil }
            if let end = chunk[..<count].firstIndex(of: 0x0A) {
                line.append(contentsOf: chunk[..<end])
                return line.count <= limit ? line : nil
            }
            line.append(contentsOf: chunk[..<count])
        }
        return nil
    }

    @discardableResult
    public static func writeLine(_ descriptor: Int32, _ data: Data) -> Bool {
        var bytes = [UInt8](data)
        bytes.append(0x0A)
        var sent = 0
        while sent < bytes.count {
            let count = bytes[sent...].withUnsafeBytes { write(descriptor, $0.baseAddress, $0.count) }
            guard count > 0 else { return false }
            sent += count
        }
        return true
    }
}
