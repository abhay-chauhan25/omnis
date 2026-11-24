import Foundation
import OmnisHelperLink
import SQLite3

public enum StoreError: Error, Equatable {
    /// macOS did not let this program open the Messages database.
    case noAccess
    case failed(String)
}

/// Reads the Messages database. Opened read-only, and every question it can
/// answer is written out below: there is no way to run any other.
public final class MessageStore {
    public static let maxMessages = 60
    public static let maxChats = 40
    public static let maxDays = 365
    public static let maxTextCharacters = 1_200
    /// A few characters can be made of very many bytes, so the bytes are capped too.
    public static let maxTextBytes = 6_000
    /// The most rows looked through for one search.
    static let maxScanned = 20_000
    /// Seconds between 1970 and 2001, where Messages starts counting.
    static let epoch = 978_307_200.0

    private var database: OpaquePointer?

    public init(path: String) throws {
        var handle: OpaquePointer?
        let status = sqlite3_open_v2(path, &handle, SQLITE_OPEN_READONLY, nil)
        guard status == SQLITE_OK, let handle else {
            if let handle { sqlite3_close(handle) }
            throw Self.error(status, at: path)
        }
        database = handle
        sqlite3_busy_timeout(handle, 2000)
        sqlite3_exec(handle, "PRAGMA query_only = ON", nil, nil, nil)
        // Opening succeeds even without permission; the first read is what fails.
        var probe: OpaquePointer?
        let prepared = sqlite3_prepare_v2(handle, "SELECT COUNT(*) FROM sqlite_master", -1, &probe, nil)
        let stepped = prepared == SQLITE_OK ? sqlite3_step(probe) : prepared
        sqlite3_finalize(probe)
        guard stepped == SQLITE_ROW else {
            sqlite3_close(handle)
            database = nil
            throw Self.error(stepped, at: path)
        }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    private static func error(_ status: Int32, at path: String) -> StoreError {
        // Without Full Disk Access the file is there but cannot be opened or read.
        if [SQLITE_CANTOPEN, SQLITE_AUTH, SQLITE_PERM, SQLITE_IOERR, SQLITE_NOTADB].contains(status & 0xFF),
           FileManager.default.fileExists(atPath: path) || !FileManager.default.isReadableFile(atPath: (path as NSString).deletingLastPathComponent) {
            return .noAccess
        }
        return .failed("the Messages database could not be opened (\(status))")
    }

    private enum Value {
        case text(String)
        case number(Int64)
    }

    /// Runs one of the fixed questions. Values are bound, never pasted into the text.
    private func rows(_ sql: String, _ values: [Value], each: (OpaquePointer) -> Void) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.failed(String(cString: sqlite3_errmsg(database)))
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            switch value {
            case .text(let text): sqlite3_bind_text(statement, Int32(index + 1), text, -1, transient)
            case .number(let number): sqlite3_bind_int64(statement, Int32(index + 1), number)
            }
        }
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_ROW { each(statement) } else if status == SQLITE_DONE { return } else {
                throw StoreError.failed(String(cString: sqlite3_errmsg(database)))
            }
        }
    }

    private static func string(_ statement: OpaquePointer, _ column: Int32) -> String {
        sqlite3_column_text(statement, column).map { String(cString: $0) } ?? ""
    }

    /// Messages counts in billionths of a second since 2001; very old rows count in seconds.
    static func seconds(_ stored: Int64) -> Double {
        (stored > 100_000_000_000 ? Double(stored) / 1_000_000_000 : Double(stored)) + epoch
    }

    static func stored(_ date: Date) -> Int64 {
        Int64((date.timeIntervalSince1970 - epoch) * 1_000_000_000)
    }

    private static func words(_ statement: OpaquePointer, text: Int32, body: Int32) -> String {
        var found = string(statement, text)
        if found.isEmpty, let bytes = sqlite3_column_blob(statement, body) {
            let count = Int(sqlite3_column_bytes(statement, body))
            found = TypedStream.text(from: Data(bytes: bytes, count: count)) ?? ""
        }
        // The mark Messages uses where a picture or file sits.
        found = found.replacingOccurrences(of: "\u{FFFC}", with: "[attachment]")
        return tidy(found)
    }

    /// Cuts a message to size and drops characters that do not show but can
    /// hide or reorder what does: controls, direction marks, zero-width marks.
    static func tidy(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        var bytes = 0
        var combining = 0
        for scalar in text.unicodeScalars {
            if scalar == "\n" || scalar == "\t" {
                // kept
            } else if scalar.properties.generalCategory == .control || scalar.properties.generalCategory == .format
                        || scalar.properties.isBidiControl {
                continue
            }
            // A long run of marks stacked on one letter is cut short.
            combining = scalar.properties.generalCategory == .nonspacingMark ? combining + 1 : 0
            if combining > 4 { continue }
            let size = UTF8.width(scalar)
            if bytes + size > maxTextBytes { break }
            bytes += size
            scalars.append(scalar)
        }
        return String(String(scalars).prefix(maxTextCharacters))
    }

    /// The conversations with the most recent messages, newest first.
    public func chats(limit: Int) throws -> [ReaderChat] {
        var chats: [ReaderChat] = []
        var rowIDs: [Int64] = []
        try rows("""
            SELECT c.ROWID, c.chat_identifier, c.display_name, c.style, MAX(m.date)
            FROM chat c JOIN chat_message_join j ON j.chat_id = c.ROWID JOIN message m ON m.ROWID = j.message_id
            GROUP BY c.ROWID ORDER BY MAX(m.date) DESC LIMIT ?
            """, [.number(Int64(max(1, min(limit, Self.maxChats))))]) { row in
            rowIDs.append(sqlite3_column_int64(row, 0))
            // Style 43 is a group; 45 is one person.
            chats.append(ReaderChat(id: Self.string(row, 1), name: Self.string(row, 2), group: sqlite3_column_int64(row, 3) == 43,
                                    last: Self.seconds(sqlite3_column_int64(row, 4))))
        }
        for (index, rowID) in rowIDs.enumerated() {
            try rows("SELECT h.id FROM chat_handle_join j JOIN handle h ON h.ROWID = j.handle_id WHERE j.chat_id = ? LIMIT 30",
                     [.number(rowID)]) { row in chats[index].people.append(Self.string(row, 0)) }
        }
        return chats
    }

    private static let messageColumns = """
        SELECT c.chat_identifier, m.date, m.is_from_me, COALESCE(h.id, ''), m.text, m.attributedBody
        FROM message m JOIN chat_message_join j ON j.message_id = m.ROWID JOIN chat c ON c.ROWID = j.chat_id
        LEFT JOIN handle h ON h.ROWID = m.handle_id
        """

    private static func message(_ row: OpaquePointer) -> ReaderMessage {
        let mine = sqlite3_column_int64(row, 2) != 0
        let sender = mine ? "" : string(row, 3)
        return ReaderMessage(chat: string(row, 0), time: seconds(sqlite3_column_int64(row, 1)), fromMe: mine,
                             sender: sender, text: hidingCodes(words(row, text: 4, body: 5), sender: sender))
    }

    static let hiddenCode = "[hidden: this looks like a verification code or a sign-in link]"
    static let hiddenAutomated = "[hidden: sent by an automated short number]"

    private static let codeWords = try! NSRegularExpression(
        pattern: #"\b(code|codes|otp|passcode|pass code|one[- ]time|verif\w*|2fa|two[- ]factor|authenticat\w*|security|log ?in|sign ?in|pin|password|reset|confirm\w*)\b"#,
        options: [.caseInsensitive])
    private static let codeDigits = try! NSRegularExpression(pattern: #"(?<![\d.,/])(\d[ -]?){3,7}\d(?![\d/])|\b[A-Z]-\d{4,8}\b"#)
    private static let link = try! NSRegularExpression(pattern: #"https?://"#, options: [.caseInsensitive])

    /// Sign-in codes and reset links are worth more to a thief than any other
    /// message, and nothing OMNIS does needs them. They never leave this
    /// program: the words are replaced before anything is searched or sent on.
    static func hidingCodes(_ text: String, sender: String) -> String {
        guard !text.isEmpty else { return text }
        // Banks and services send from short numbers: digits only, a handful of them.
        if !sender.isEmpty, sender.count <= 8, sender.allSatisfy(\.isNumber) { return hiddenAutomated }
        let whole = NSRange(text.startIndex..., in: text)
        guard codeWords.firstMatch(in: text, range: whole) != nil else { return text }
        let hasDigits = codeDigits.firstMatch(in: text, range: whole) != nil
        let hasLink = link.firstMatch(in: text, range: whole) != nil
        return hasDigits || hasLink ? hiddenCode : text
    }

    private static func since(_ days: Int, now: Date) -> Int64 {
        stored(now.addingTimeInterval(-Double(max(1, min(days, maxDays))) * 86_400))
    }

    /// The latest messages in one conversation, oldest first. Reactions are left out.
    public func messages(chat: String, days: Int, limit: Int, now: Date = Date()) throws -> [ReaderMessage] {
        var found: [ReaderMessage] = []
        let most = max(1, min(limit, Self.maxMessages))
        // Messages set to be sent later are not sent yet, and unsent ones have no words: neither is listed.
        try rows(Self.messageColumns + " WHERE c.chat_identifier = ? AND m.date >= ? AND m.date <= ? AND m.associated_message_type = 0 "
                 + "AND ((m.text IS NOT NULL AND m.text != '') OR m.attributedBody IS NOT NULL) ORDER BY m.date DESC LIMIT ?",
                 [.text(chat), .number(Self.since(days, now: now)), .number(Self.stored(now)), .number(Int64(most + 200))]) { row in
            guard found.count < most else { return }
            let message = Self.message(row)
            if !message.text.isEmpty { found.append(message) }
        }
        return found.reversed()
    }

    /// Messages containing every one of the words, newest first.
    public func search(text: String, days: Int, limit: Int, now: Date = Date()) throws -> [ReaderMessage] {
        let wanted = text.lowercased().split(separator: " ").map(String.init).filter { !$0.isEmpty }.prefix(8)
        guard !wanted.isEmpty else { return [] }
        let most = max(1, min(limit, Self.maxMessages))
        var found: [ReaderMessage] = []
        // The words may be in the packed form, which the database cannot search, so recent rows are read and checked here.
        try rows(Self.messageColumns + " WHERE m.date >= ? AND m.date <= ? AND m.associated_message_type = 0 ORDER BY m.date DESC LIMIT ?",
                 [.number(Self.since(days, now: now)), .number(Self.stored(now)), .number(Int64(Self.maxScanned))]) { row in
            guard found.count < most else { return }
            let message = Self.message(row)
            let lowered = message.text.lowercased()
            if wanted.allSatisfy(lowered.contains) { found.append(message) }
        }
        return found
    }
}
