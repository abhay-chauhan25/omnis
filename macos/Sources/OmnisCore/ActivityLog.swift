import Foundation

/// The audit record, turned into plain lines for the Activity view. It reads
/// what `AuditLog` already wrote and adds nothing to it.
public enum ActivityLog {
    public enum Filter: String, CaseIterable, Sendable {
        case all = "All"
        case changes = "Changes"
        case reads = "Reads"
        case searches = "Searches"
        /// Anything that did not go ahead: refused by OMNIS, or declined by the user.
        case refused = "Refused"
    }

    public enum Tone: Equatable, Sendable {
        case plain
        /// Something of the user's was changed, after they confirmed it.
        case changed
        /// It did not go ahead, or it failed.
        case stopped
    }

    public struct Row: Equatable, Identifiable, Sendable {
        public let id: String
        public let time: Date
        public let title: String
        public let outcome: String
        public let detail: String
        public let groups: Set<Filter>
        public let tone: Tone
        /// How many identical records in a row this line stands for.
        public var count = 1

        func sameThing(as other: Row) -> Bool {
            title == other.title && outcome == other.outcome && detail == other.detail
        }
    }

    public struct Day: Equatable, Identifiable, Sendable {
        public let title: String
        public let rows: [Row]
        public var id: String { "\(title) \(rows.first?.id ?? "")" }
    }

    private static let stamps = ISO8601DateFormatter()
    private static let dayNames: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "EEEE d MMMM"
        return formatter
    }()

    /// Every record as a line, newest first. Identical records that follow
    /// one another on the same day are shown once, with a count.
    public static func rows(from records: [AuditLog.Record], calendar: Calendar = .current) -> [Row] {
        // A row is known by its time and its place among records of that same
        // second, so it keeps its identity when older records drop off the log.
        var seen: [String: Int] = [:]
        var ids: [String] = []
        for record in records {
            let place = seen[record.time, default: 0]
            seen[record.time] = place + 1
            ids.append("\(record.time)#\(place)")
        }
        var rows: [Row] = []
        for (index, record) in records.enumerated().reversed() {
            guard let time = stamps.date(from: record.time) else { continue }
            let row = describe(record, id: ids[index], time: time)
            if let last = rows.last, last.sameThing(as: row), calendar.isDate(last.time, inSameDayAs: row.time) {
                rows[rows.count - 1].count += 1
            } else {
                rows.append(row)
            }
        }
        return rows
    }

    /// The rows that pass the filter and contain the typed words, grouped by day.
    public static func days(_ rows: [Row], filter: Filter = .all, matching text: String = "",
                            calendar: Calendar = .current, now: Date = Date()) -> [Day] {
        let words = text.lowercased().split(separator: " ").map(String.init)
        let kept = rows.filter { row in
            guard filter == .all || row.groups.contains(filter) else { return false }
            let line = "\(row.title) \(row.outcome) \(row.detail)".lowercased()
            return words.allSatisfy(line.contains)
        }
        let formatter = dayNames
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        let today = calendar.startOfDay(for: now)
        var days: [Day] = []
        var current: (title: String, rows: [Row])?
        for row in kept {
            let start = calendar.startOfDay(for: row.time)
            let gap = calendar.dateComponents([.day], from: start, to: today).day ?? 0
            let title = gap == 0 ? "Today" : gap == 1 ? "Yesterday" : formatter.string(from: row.time)
            if current?.title != title {
                if let current { days.append(Day(title: current.title, rows: current.rows)) }
                current = (title, [])
            }
            current?.rows.append(row)
        }
        if let current { days.append(Day(title: current.title, rows: current.rows)) }
        return days
    }

    // MARK: Wording

    static func describe(_ record: AuditLog.Record, id: String, time: Date) -> Row {
        let detail = record.detail ?? ""
        let target = record.target ?? ""
        let failed = record.outcome == "error"
        func row(_ title: String, _ outcome: String, _ detail: String = "", _ groups: Set<Filter> = [], _ tone: Tone = .plain) -> Row {
            Row(id: id, time: time, title: title, outcome: outcome, detail: detail, groups: groups,
                tone: failed && tone == .plain ? .stopped : tone)
        }
        let action = record.action
        switch action {
        case "launch":
            return failed ? row("Could not open \(target)", "failed", detail) : row("Opened \(target)", "done")
        case "ask":
            switch record.outcome {
            case "ok":
                let place = detail.contains("route claude") ? "with Claude" : detail.contains("route local") ? "on this Mac" : ""
                return row("Answered a question", place.isEmpty ? "done" : place, detail)
            case "stopped": return row("An answer was stopped", "you stopped it")
            default: return row("A question could not be answered", "failed", detail)
            }
        case "attach": return row("Read an attached file", "done", detail, [.reads])
        case "web_search":
            return failed ? row("A web search failed", "failed", detail, [.searches]) : row("Searched the web", "done", detail, [.searches])
        case "search_consent":
            switch record.outcome {
            case "asked": return row("Asked whether this chat may search", "asked you", "the chat holds personal information", [.searches])
            case "allowed": return row("Searches allowed in a chat", "you allowed", detail, [.searches])
            case "declined": return row("Searches declined in a chat", "you declined", detail, [.searches, .refused], .stopped)
            default: return row("The search question went unanswered", "nothing searched", "", [.searches, .refused], .stopped)
            }
        case "tool_refused":
            let who = record.kind == "advisor" ? "The advisor asked for" : "Claude asked for"
            return row("\(who) \(name(of: target))", "refused", detail, [.refused], .stopped)
        case "calendar_read":
            if failed { return row("Your calendar could not be read", "failed", detail, [.reads]) }
            return detail.hasSuffix("for the dashboard")
                ? row("Read your calendar for the dashboard", "done", String(detail.dropLast(", for the dashboard".count)), [.reads])
                : row("Read your calendar", "done", detail, [.reads])
        case "calendar_propose":
            return record.outcome == "ok" ? row("Prepared a calendar change for you to check", "shown", words(detail))
                : row("A change could not be prepared", "refused", "", [.refused], .stopped)
        case "calendar_change":
            return change(record, what: calendarChange(detail), row)
        case "project_propose": return row("Prepared a new project for you to check", "shown")
        case "project_create":
            switch record.outcome {
            case "ok": return row("Set up the project \(target)", "you confirmed", detail, [.changes], .changed)
            case "declined": return row("A new project was not set up", "you declined", "", [.changes, .refused], .stopped)
            default: return row("The project \(target) could not be set up", "failed", detail, [.changes])
            }
        case "project_mode": return row("Opened \(target) in project mode", "done", detail)
        case "project_session": return row("Started a Claude Code session in \(target)", "done", detail)
        case "note": return row("Captured a note", "done", "", [.changes], .changed)
        case "open_source": return row("Opened a source", "done", target)
        case "service":
            let acted = detail.hasPrefix("Controlled")
            return row(detail.isEmpty ? "Used a service" : detail, "done", "", detail.hasPrefix("Searched") ? [.searches] : acted ? [.changes] : [.reads])
        case "session_setting": return row("Claude Code did not accept a change of model or effort", "refused", "", [.refused], .stopped)
        case "hotkey": return row("The keyboard shortcut could not be set", "failed", detail)
        default:
            if action.hasSuffix("_propose") {
                return row("Prepared a change in \(name(of: String(action.dropLast(8)))) for you to check", "shown", words(detail))
            }
            if action.hasSuffix("_change") {
                return change(record, what: "\(name(of: String(action.dropLast(7)))): \(words(detail))", row)
            }
            return row(words(action).prefix(1).uppercased() + words(action).dropFirst(), record.outcome, [target, detail].filter { !$0.isEmpty }.joined(separator: ", "))
        }
    }

    private static func change(_ record: AuditLog.Record, what: String,
                               _ row: (String, String, String, Set<Filter>, Tone) -> Row) -> Row {
        switch record.outcome {
        case "ok": return row(what, "you confirmed", "", [.changes], .changed)
        case "declined": return row(what, "you declined", "nothing was changed", [.changes, .refused], .stopped)
        default: return row(what, "failed", "nothing was changed", [.changes], .stopped)
        }
    }

    private static func calendarChange(_ kind: String) -> String {
        switch kind {
        case "update_event": return "Change an event"
        case "delete_event": return "Delete an event"
        case "create_calendar": return "Create a calendar"
        case "rename_calendar": return "Rename a calendar"
        case "delete_calendar": return "Delete a calendar"
        case "": return "A calendar change"
        default: return "Add an event"
        }
    }

    /// "web_search" as "web search", "mail" as "Mail".
    static func name(of tool: String) -> String {
        switch tool {
        case "web_search": return "a web search"
        case "reminders": return "Reminders"
        case "messages": return "Messages"
        case "mail": return "Mail"
        case "photos": return "Photos"
        case "github": return "GitHub"
        case "spotify": return "Spotify"
        default: return words(tool)
        }
    }

    private static func words(_ text: String) -> String {
        text.replacingOccurrences(of: "_", with: " ")
    }
}
