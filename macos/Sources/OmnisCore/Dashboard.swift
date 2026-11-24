import Foundation

extension OmnisPaths {
    public static var notesFile: URL { supportDirectory.appendingPathComponent("notes.md") }
}

extension AuditLog {
    /// The most recent records in a log file, oldest first. Only the end of
    /// the file is read, so a long log stays cheap to look at.
    public static func recent(at url: URL, limit: Int = 4000, maxBytes: Int = 1_500_000) -> [Record] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard let data = try? handle.readToEnd() else { return [] }
        var lines = data.split(separator: 0x0A)
        // The first line may be cut in half when only the end was read.
        if start > 0, !lines.isEmpty { lines.removeFirst() }
        let decoder = JSONDecoder()
        return Array(lines.compactMap { try? decoder.decode(Record.self, from: Data($0)) }.suffix(limit))
    }
}

/// What the dashboard shows, worked out from the record OMNIS already keeps
/// of what it did. Nothing here records anything new about the user.
public enum DashboardData {
    /// One formatter for every record: making one per record is slow on a long log.
    private static let stamps = ISO8601DateFormatter()

    static func date(_ record: AuditLog.Record) -> Date? {
        stamps.date(from: record.time)
    }

    // MARK: Recent activity

    public struct ActivityLine: Equatable, Sendable, Identifiable {
        public let time: Date
        public let text: String
        public var id: String { "\(time.timeIntervalSince1970)-\(text)" }
    }

    /// One plain line for a record, or nil for records not worth showing.
    static func describe(_ record: AuditLog.Record) -> String? {
        guard record.outcome == "ok" else { return nil }
        switch record.action {
        case "launch": return record.target.map { "Opened \($0)" }
        case "web_search": return "Searched the web" + (record.detail.map { ", \($0)" } ?? "")
        case "calendar_read":
            // The dashboard's own look at today is not something the user asked for.
            return record.detail?.hasSuffix("for the dashboard") == true ? nil : "Read your calendar"
        case "attach": return "Read an attached file"
        case "note": return "Captured a note"
        case "calendar_change":
            switch record.detail {
            case "update_event": return "Changed an event, after you confirmed"
            case "delete_event": return "Deleted an event, after you confirmed"
            case "create_calendar": return "Created a calendar, after you confirmed"
            case "rename_calendar": return "Renamed a calendar, after you confirmed"
            case "delete_calendar": return "Deleted a calendar, after you confirmed"
            default: return "Added an event, after you confirmed"
            }
        case "ask":
            let detail = record.detail ?? ""
            if detail.contains("route claude") { return "Answered a question with Claude" }
            if detail.contains("route local") { return "Answered a question on this Mac" }
            return "Answered a question"
        default: return nil
        }
    }

    /// The latest things OMNIS did, newest first.
    public static func activity(from records: [AuditLog.Record], limit: Int = 7) -> [ActivityLine] {
        var lines: [ActivityLine] = []
        for record in records.reversed() {
            guard let text = describe(record), let time = date(record) else { continue }
            lines.append(ActivityLine(time: time, text: text))
            if lines.count == limit { break }
        }
        return lines
    }

    // MARK: Launch tiles

    /// Registry entries for the launch tiles: the ones opened most in the
    /// last `days`, most used first, then filled up with projects and launchers.
    public static func tiles(from records: [AuditLog.Record], entries: [RegistryEntry], limit: Int = 6, days: Int = 30,
                             now: Date = Date()) -> [RegistryEntry] {
        let since = now.addingTimeInterval(-Double(days) * 86_400)
        var counts: [String: Int] = [:]
        var latest: [String: Date] = [:]
        for record in records where record.action == "launch" && record.outcome == "ok" {
            guard let name = record.target, let kind = record.kind, let time = date(record), time >= since else { continue }
            let id = "\(kind):\(name)"
            counts[id, default: 0] += 1
            latest[id] = max(latest[id] ?? time, time)
        }
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var chosen = counts.keys.compactMap { byID[$0] }.sorted {
            let a = counts[$0.id] ?? 0, b = counts[$1.id] ?? 0
            if a != b { return a > b }
            return (latest[$0.id] ?? .distantPast) > (latest[$1.id] ?? .distantPast)
        }
        // Until there is enough history, the user's own projects and launchers fill the row.
        for entry in entries where entry.kind != .app && !chosen.contains(entry) { chosen.append(entry) }
        return Array(chosen.prefix(limit))
    }

    // MARK: Thirty days of use

    public struct History: Equatable, Sendable {
        /// Questions answered on each of the last thirty days, oldest first; today is last.
        public var perDay: [Int]
        public var questions: Int
        public var tokens: Int
        public var tokensToday: Int
        /// The hour of the day (0 to 23) with the most questions, if there were any.
        public var busiestHour: Int?

        /// Each day as a level from 0 (nothing) to 4 (the busiest), for the heatmap.
        public var levels: [Int] {
            let top = perDay.max() ?? 0
            return perDay.map { count in
                guard count > 0, top > 0 else { return 0 }
                return min(4, 1 + Int((Double(count) / Double(top) * 3).rounded(.down)))
            }
        }
    }

    static func tokens(in detail: String?) -> Int {
        guard let detail else { return 0 }
        var total = 0
        for part in detail.components(separatedBy: ", ") where part.hasSuffix(" tokens") {
            let words = part.split(separator: " ")
            if words.count == 3, words[0] == "in" || words[0] == "out", let count = Int(words[1]) { total += count }
        }
        return total
    }

    public static func history(from records: [AuditLog.Record], days: Int = 30, now: Date = Date(),
                               calendar: Calendar = .current) -> History {
        var perDay = Array(repeating: 0, count: days)
        var hours = Array(repeating: 0, count: 24)
        var total = 0, today = 0
        let startOfToday = calendar.startOfDay(for: now)
        for record in records where record.action == "ask" && record.outcome == "ok" {
            guard let time = date(record),
                  let ago = calendar.dateComponents([.day], from: calendar.startOfDay(for: time), to: startOfToday).day,
                  (0..<days).contains(ago) else { continue }
            perDay[days - 1 - ago] += 1
            hours[calendar.component(.hour, from: time)] += 1
            let used = tokens(in: record.detail)
            total += used
            if ago == 0 { today += used }
        }
        let questions = perDay.reduce(0, +)
        let busiest = questions == 0 ? nil : hours.firstIndex(of: hours.max() ?? 0)
        return History(perDay: perDay, questions: questions, tokens: total, tokensToday: today, busiestHour: busiest)
    }

    /// "1.9M", "41k", "820".
    public static func compact(_ count: Int) -> String {
        if count >= 1_000_000 { return String(format: "%.1fM", Double(count) / 1_000_000) }
        if count >= 1000 { return "\(Int((Double(count) / 1000).rounded()))k" }
        return "\(count)"
    }

    // MARK: Today

    public struct AgendaRow: Equatable, Sendable, Identifiable {
        public let id: String
        public let time: String
        public let title: String
        public let calendar: String
        public let start: Date
        public let isNext: Bool
    }

    /// Today's remaining and current events, in order, with the next one marked.
    public static func agenda(from events: [CalendarEvent], now: Date = Date(), calendar: Calendar = .current,
                              limit: Int = 6) -> [AgendaRow] {
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = Locale(identifier: "en_GB")
        time.dateFormat = "HH:mm"
        let upcoming = events.filter { calendar.isDate($0.start, inSameDayAs: now) || ($0.start < now && $0.end > now) }
            .filter { $0.end > now }
            .sorted { ($0.allDay ? 0 : 1, $0.start, $0.title) < ($1.allDay ? 0 : 1, $1.start, $1.title) }
        let next = upcoming.first { !$0.allDay && $0.start > now }
        return upcoming.prefix(limit).enumerated().map { index, event in
            AgendaRow(id: "\(index)-\(event.key)", time: event.allDay ? "all day" : time.string(from: event.start),
                      title: CalendarFormatter.clean(event.title).isEmpty ? "(no title)" : CalendarFormatter.clean(event.title),
                      calendar: CalendarFormatter.clean(event.calendar), start: event.start,
                      isNext: next.map { $0.key == event.key && $0.start == event.start } ?? false)
        }
    }

    /// "in 28 min", "in 2 h 5 min", or nil when nothing more is on today.
    public static func untilNext(_ rows: [AgendaRow], now: Date = Date()) -> String? {
        guard let next = rows.first(where: \.isNext) else { return nil }
        let minutes = max(0, Int((next.start.timeIntervalSince(now) / 60).rounded()))
        if minutes < 60 { return "in \(minutes) min" }
        return minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min"
    }

    public static func greeting(now: Date = Date(), calendar: Calendar = .current) -> String {
        switch calendar.component(.hour, from: now) {
        case 5..<12: return "Good morning."
        case 12..<18: return "Good afternoon."
        default: return "Good evening."
        }
    }
}

/// Finds Claude Code sessions running on this Mac and the folder each is working in.
public enum SessionScanner {
    public struct Session: Equatable, Sendable, Identifiable {
        public let pid: Int
        /// How long it has been running, as `ps` reports it ("41:07", "02-03:10:00").
        public let elapsed: String
        public let folder: String
        public var id: Int { pid }
        public var project: String { URL(fileURLWithPath: folder).lastPathComponent }

        /// "41 min", "3 h", "2 days".
        public var age: String {
            var days = 0
            var rest = Substring(elapsed)
            if let dash = elapsed.firstIndex(of: "-") {
                days = Int(elapsed[..<dash]) ?? 0
                rest = elapsed[elapsed.index(after: dash)...]
            }
            let parts = rest.split(separator: ":").compactMap { Int($0) }
            let hours = parts.count == 3 ? parts[0] : 0
            let minutes = parts.count >= 2 ? parts[parts.count - 2] : 0
            if days > 0 { return days == 1 ? "1 day" : "\(days) days" }
            if hours > 0 { return "\(hours) h" }
            return "\(max(minutes, 1)) min"
        }
    }

    /// Runs a program and returns what it printed. Replaced in tests.
    public typealias Runner = @Sendable (_ program: String, _ arguments: [String]) -> String

    public static let system: Runner = { program, arguments in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// The process list: only the `claude` command-line program counts, not the desktop app.
    static func candidates(in listing: String) -> [(pid: Int, elapsed: String)] {
        listing.split(separator: "\n").compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard fields.count == 3, let pid = Int(fields[0]) else { return nil }
            let command = String(fields[2]).trimmingCharacters(in: .whitespaces)
            guard command == "claude" || command.hasSuffix("/claude") else { return nil }
            return (pid, String(fields[1]))
        }
    }

    /// `lsof -Fn` prints the folder on a line starting with "n".
    static func folder(in listing: String) -> String? {
        listing.split(separator: "\n").first { $0.hasPrefix("n/") }.map { String($0.dropFirst()) }
    }

    /// Running sessions, longest-running last. Sessions in `excluding` folders
    /// (OMNIS's own) and in the home folder itself are left out.
    public static func scan(excluding: [URL] = [], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            run: Runner = system) -> [Session] {
        let hidden = Set(excluding.map(\.standardizedFileURL.path))
        var sessions: [Session] = []
        for candidate in candidates(in: run("/bin/ps", ["-axo", "pid=,etime=,comm="])).prefix(40) {
            guard let folder = folder(in: run("/usr/sbin/lsof", ["-a", "-d", "cwd", "-p", "\(candidate.pid)", "-Fn"])) else { continue }
            let path = URL(fileURLWithPath: folder).standardizedFileURL.path
            guard !hidden.contains(path), path != home.standardizedFileURL.path, path != "/" else { continue }
            sessions.append(Session(pid: candidate.pid, elapsed: candidate.elapsed, folder: path))
        }
        return sessions
    }
}

/// Quick notes, kept in one plain text file the user can open anywhere.
public struct NotesStore: Sendable {
    public let url: URL

    public init(url: URL = OmnisPaths.notesFile) {
        self.url = url
    }

    static func stamp(_ date: Date, calendar: Calendar) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// Adds one note as a line with the time it was written. Returns false if it could not be saved.
    @discardableResult
    public func add(_ text: String, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let note = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
        guard !note.isEmpty else { return false }
        let line = "- \(Self.stamp(now, calendar: calendar))  \(String(note.prefix(2000)))\n"
        let fileManager = FileManager.default
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                         attributes: [.posixPermissions: 0o700])
        if !fileManager.fileExists(atPath: url.path) {
            guard fileManager.createFile(atPath: url.path, contents: Data("# OMNIS notes\n\n".utf8),
                                         attributes: [.posixPermissions: 0o600]) else { return false }
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            return true
        } catch {
            return false
        }
    }

    /// How many notes were written today.
    public func countToday(now: Date = Date(), calendar: Calendar = .current) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return 0 }
        let prefix = "- " + Self.stamp(now, calendar: calendar).prefix(10)
        return text.split(separator: "\n").filter { $0.hasPrefix(prefix) }.count
    }
}

/// A countdown for a stretch of focused work.
public struct FocusTimer: Equatable, Sendable {
    public var length: TimeInterval
    /// When the running stretch ends, or nil when stopped.
    public var endsAt: Date?

    public init(length: TimeInterval = 25 * 60) {
        self.length = length
    }

    public var isRunning: Bool { endsAt != nil }

    public mutating func start(now: Date = Date()) { endsAt = now.addingTimeInterval(length) }
    public mutating func stop() { endsAt = nil }

    public func remaining(now: Date = Date()) -> TimeInterval {
        guard let endsAt else { return length }
        return max(0, endsAt.timeIntervalSince(now))
    }

    public func isFinished(now: Date = Date()) -> Bool {
        guard let endsAt else { return false }
        return now >= endsAt
    }

    /// "25:00"
    public func label(now: Date = Date()) -> String {
        let seconds = Int(remaining(now: now).rounded(.up))
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
