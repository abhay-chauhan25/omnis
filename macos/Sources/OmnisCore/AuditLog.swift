import Foundation

/// Append-only record of what OMNIS did: one JSON object per line.
/// It stores the action and the target's name, never what was typed.
public final class AuditLog: @unchecked Sendable {
    public struct Record: Codable, Equatable, Sendable {
        public var time: String
        public var action: String
        public var kind: String?
        public var target: String?
        public var outcome: String
        public var detail: String?
    }

    private let url: URL
    private let queue = DispatchQueue(label: "omnis.audit")
    private let now: @Sendable () -> Date

    public init(url: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.now = now
    }

    public func record(action: String, kind: String? = nil, target: String? = nil, outcome: String, detail: String? = nil) {
        let stamp = ISO8601DateFormatter().string(from: now())
        let record = Record(time: stamp, action: action, kind: kind, target: target, outcome: outcome, detail: detail)
        queue.async { [url] in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            guard var line = try? encoder.encode(record) else { return }
            line.append(0x0A)
            let fileManager = FileManager.default
            try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                             attributes: [.posixPermissions: 0o700])
            if !fileManager.fileExists(atPath: url.path) {
                fileManager.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600])
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: line)
        }
    }

    /// Waits until everything recorded so far is on disk. Used by tests and at quit.
    public func flush() {
        queue.sync {}
    }
}
