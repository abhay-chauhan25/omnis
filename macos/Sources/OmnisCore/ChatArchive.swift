import Foundation

/// One message of a saved chat, as it is written to disk.
///
/// Only words are kept. A file's contents and pictures are not: only the
/// file's name. Previews (a new event, a reminder) are kept as one line each
/// saying what became of them, so a saved chat can never carry a live button.
public struct SavedMessage: Codable, Equatable, Sendable {
    public var role: String
    public var text: String
    /// "done", "stopped" or "failed".
    public var state: String
    public var failure: String?
    public var sourceLine: String?
    public var sources: [SavedSource]
    /// What was read, used or previewed for this answer, a line each.
    public var notes: [String]
    /// Names of the files that went with a user's message.
    public var files: [String]
    /// True if the answer's text was left out because it was about an email.
    public var withheld: Bool

    public init(role: String, text: String, state: String = "done", failure: String? = nil, sourceLine: String? = nil,
                sources: [SavedSource] = [], notes: [String] = [], files: [String] = [], withheld: Bool = false) {
        self.role = role
        self.text = text
        self.state = state
        self.failure = failure
        self.sourceLine = sourceLine
        self.sources = sources
        self.notes = notes
        self.files = files
        self.withheld = withheld
    }
}

public struct SavedSource: Codable, Equatable, Sendable {
    public var title: String
    public var url: String

    public init(title: String, url: String) {
        self.title = title
        self.url = url
    }
}

/// A chat as it is kept on this Mac.
public struct SavedChat: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID
    public var title: String
    /// True once the user has named the chat themselves, so it is not renamed for them.
    public var named: Bool
    public var created: Date
    public var updated: Date
    public var pinned: Bool
    public var messages: [SavedMessage]
    /// The chat held something personal: a file, the calendar, an email.
    public var personal: Bool
    /// The chat held a file or other people's words. It keeps the stricter rules when opened again.
    public var othersWords: Bool
    /// The chat was given an email's text. Answers after that point are not saved.
    public var email: Bool

    public init(id: UUID = UUID(), title: String, named: Bool = false, created: Date, updated: Date, pinned: Bool = false,
                messages: [SavedMessage], personal: Bool = false, othersWords: Bool = false, email: Bool = false) {
        self.id = id
        self.title = title
        self.named = named
        self.created = created
        self.updated = updated
        self.pinned = pinned
        self.messages = messages
        self.personal = personal
        self.othersWords = othersWords
        self.email = email
    }

    /// A name for a chat from its first question: one line, not too long.
    public static func title(from messages: [SavedMessage]) -> String {
        guard let first = messages.first(where: { $0.role == "user" }) else { return "New chat" }
        let line = first.text.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        if line.isEmpty { return first.files.first.map { "About \($0)" } ?? "New chat" }
        guard line.count > maxTitleCharacters else { return line }
        // Cut at a word, so the name does not end mid-word.
        let cut = line.prefix(maxTitleCharacters)
        let words = cut.split(separator: " ")
        let whole = words.count > 1 ? words.dropLast().joined(separator: " ") : String(cut)
        return whole + "\u{2026}"
    }

    public static let maxTitleCharacters = 56
}

/// What the list of chats shows for one chat.
public struct ChatSummary: Equatable, Identifiable, Sendable {
    public let id: UUID
    public var title: String
    public var updated: Date
    public var pinned: Bool
    /// The start of the last thing said, for the second line of a row.
    public var preview: String
    public var messageCount: Int

    public init(id: UUID, title: String, updated: Date, pinned: Bool, preview: String, messageCount: Int) {
        self.id = id
        self.title = title
        self.updated = updated
        self.pinned = pinned
        self.preview = preview
        self.messageCount = messageCount
    }

    init(_ chat: SavedChat) {
        let last = chat.messages.last { !$0.text.isEmpty }
        let line = (last?.text ?? "").split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        self.init(id: chat.id, title: chat.title, updated: chat.updated, pinned: chat.pinned,
                  preview: String(line.prefix(120)), messageCount: chat.messages.count)
    }
}

/// Where a chat falls in the list, by when it was last used.
public enum ChatAge: String, CaseIterable, Sendable {
    case pinned = "Pinned"
    case today = "Today"
    case yesterday = "Yesterday"
    case week = "Earlier this week"
    case older = "Older"

    public static func of(_ summary: ChatSummary, now: Date = Date(), calendar: Calendar = .current) -> ChatAge {
        if summary.pinned { return .pinned }
        if calendar.isDate(summary.updated, inSameDayAs: now) { return .today }
        let startOfToday = calendar.startOfDay(for: now)
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: startOfToday), summary.updated >= yesterday { return .yesterday }
        if let week = calendar.date(byAdding: .day, value: -7, to: startOfToday), summary.updated >= week { return .week }
        return .older
    }

    /// The chats under their headings, newest first, leaving out headings with nothing under them.
    public static func grouped(_ summaries: [ChatSummary], now: Date = Date(),
                               calendar: Calendar = .current) -> [(age: ChatAge, chats: [ChatSummary])] {
        let sorted = summaries.sorted { $0.updated > $1.updated }
        return allCases.compactMap { age in
            let chats = sorted.filter { of($0, now: now, calendar: calendar) == age }
            return chats.isEmpty ? nil : (age, chats)
        }
    }
}

/// Keeps chats on this Mac: one file a chat, in a folder only this user can read.
///
/// Nothing here leaves the Mac. A chat that is not pinned is removed once it
/// has not been used for the number of days the user chose.
public final class ChatStore: @unchecked Sendable {
    private let folder: URL
    private let lock = NSLock()
    private var index: [UUID: ChatSummary]?

    public static let maxMessagesKept = 400
    public static let maxTextCharacters = 60_000

    public init(folder: URL) {
        self.folder = folder
    }

    private func file(_ id: UUID) -> URL {
        folder.appendingPathComponent("\(id.uuidString.lowercased()).json")
    }

    private static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return decoder
    }

    /// Writes a chat, replacing what was saved under its id. An empty chat is not saved.
    public func save(_ chat: SavedChat) throws {
        guard !chat.messages.isEmpty else { return }
        var trimmed = chat
        trimmed.messages = chat.messages.suffix(Self.maxMessagesKept).map { message in
            var kept = message
            kept.text = String(message.text.prefix(Self.maxTextCharacters))
            return kept
        }
        let data = try Self.encoder().encode(trimmed)
        try lock.withLock {
            let files = FileManager.default
            try files.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            // The folder may have been made before this rule: it is closed to other users each time.
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path)
            let target = file(chat.id)
            // Written whole to one side and moved into place, so a chat is never left half written.
            // The folder itself is closed to other users, which covers the moment before the file is.
            try data.write(to: target, options: .atomic)
            try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            if index != nil { index?[chat.id] = ChatSummary(trimmed) }
        }
    }

    public func load(_ id: UUID) -> SavedChat? {
        lock.withLock { read(file(id)) }
    }

    private func read(_ url: URL) -> SavedChat? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? Self.decoder().decode(SavedChat.self, from: data)
    }

    private func allFiles() -> [URL] {
        let found = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return found.filter { $0.pathExtension == "json" && UUID(uuidString: $0.deletingPathExtension().lastPathComponent) != nil }
    }

    /// Call with the lock held.
    private func loadIndex() -> [UUID: ChatSummary] {
        if let index { return index }
        var built: [UUID: ChatSummary] = [:]
        for url in allFiles() {
            if let chat = read(url) { built[chat.id] = ChatSummary(chat) }
        }
        index = built
        return built
    }

    /// Every saved chat, newest first.
    public func summaries() -> [ChatSummary] {
        lock.withLock { loadIndex().values.sorted { $0.updated > $1.updated } }
    }

    /// The chats whose name or words contain what was typed, newest first.
    public func search(_ words: String) -> [ChatSummary] {
        let wanted = words.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !wanted.isEmpty else { return summaries() }
        return lock.withLock {
            let known = loadIndex()
            return allFiles().compactMap { url -> ChatSummary? in
                guard let chat = read(url) else { return nil }
                let hit = chat.title.localizedCaseInsensitiveContains(wanted)
                    || chat.messages.contains { $0.text.localizedCaseInsensitiveContains(wanted) }
                return hit ? (known[chat.id] ?? ChatSummary(chat)) : nil
            }
            .sorted { $0.updated > $1.updated }
        }
    }

    public func delete(_ id: UUID) {
        lock.withLock {
            try? FileManager.default.removeItem(at: file(id))
            index?[id] = nil
        }
    }

    /// Removes every saved chat. Returns how many there were.
    @discardableResult
    public func deleteAll() -> Int {
        lock.withLock {
            let files = allFiles()
            for url in files { try? FileManager.default.removeItem(at: url) }
            index = [:]
            return files.count
        }
    }

    /// A name as it is kept: one line, not too long.
    public static func tidyTitle(_ title: String) -> String {
        let oneLine = title.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(80))
    }

    public func rename(_ id: UUID, to title: String) {
        let tidy = Self.tidyTitle(title)
        guard !tidy.isEmpty, var chat = load(id) else { return }
        chat.title = tidy
        chat.named = true
        try? save(chat)
    }

    public func setPinned(_ id: UUID, _ pinned: Bool) {
        guard var chat = load(id) else { return }
        chat.pinned = pinned
        try? save(chat)
    }

    /// Removes chats not used for `days` days, leaving pinned ones. Zero days keeps everything.
    /// Returns how many were removed.
    /// How many chats `prune` would remove, without removing any.
    public func countPast(days: Int, now: Date = Date(), keeping kept: UUID? = nil) -> Int {
        guard days > 0 else { return 0 }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return lock.withLock { loadIndex().values.filter { !$0.pinned && $0.updated < limit && $0.id != kept }.count }
    }

    /// `keeping` is the chat that is open, which is never removed from under the user.
    @discardableResult
    public func prune(olderThanDays days: Int, now: Date = Date(), keeping kept: UUID? = nil) -> Int {
        guard days > 0 else { return 0 }
        let limit = now.addingTimeInterval(-Double(days) * 86_400)
        return lock.withLock {
            var removed = 0
            for (id, summary) in loadIndex() where !summary.pinned && summary.updated < limit && id != kept {
                try? FileManager.default.removeItem(at: file(id))
                index?[id] = nil
                removed += 1
            }
            return removed
        }
    }
}

public extension OmnisPaths {
    static var chatsFolder: URL { supportDirectory.appendingPathComponent("chats", isDirectory: true) }
    static var memoryFile: URL { supportDirectory.appendingPathComponent("memory.json") }
}
