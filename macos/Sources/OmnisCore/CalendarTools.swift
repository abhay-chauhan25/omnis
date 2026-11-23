import Foundation

/// What the app allowed for one question.
public struct CalendarToolAccess: Equatable, Sendable {
    /// The calendar may be read.
    public let calendar: Bool
    /// Changes may be prepared for the user to confirm.
    public let write: Bool
    public let deletes: DeleteLevel

    public init(calendar: Bool, write: Bool = false, deletes: DeleteLevel = .none) {
        self.calendar = calendar
        self.write = write
        self.deletes = deletes
    }
}

public enum CalendarToolOutcome: Sendable, Equatable {
    /// Text for the model. `events` is below zero when a count means nothing.
    case read(content: String, summary: String, events: Int)
    /// A change for the user to confirm. Nothing has been done.
    case proposal(CalendarChange)
}

/// Carries out the calendar tools a model can ask for, whichever model it is.
///
/// A read returns text. A change returns only a description of the change
/// for the window to show: nothing here can alter the calendar. Each kind is
/// refused unless the app allowed it for the question being answered.
public final class CalendarTools: Sendable {
    public let reader: (any CalendarReading)?
    private let refs = EventRefs()

    public init(reader: (any CalendarReading)?) {
        self.reader = reader
    }

    public static let writeTools: Set<String> = [
        "calendar_create_event", "calendar_update_event", "calendar_delete_event",
        "calendar_create_calendar", "calendar_rename_calendar", "calendar_delete_calendar",
    ]
    public static let readTools: Set<String> = ["calendar_events", "calendar_event_details", "calendar_list"]

    /// Checks everything that can be checked without the calendar, then
    /// returns the work still to do. Throws if the request is refused.
    public func prepare(tool: String, arguments: [String: String],
                        access: CalendarToolAccess) throws -> @Sendable () async throws -> CalendarToolOutcome {
        let writing = Self.writeTools.contains(tool)
        guard access.calendar, let calendar = reader else {
            throw CalendarError.refused("the calendar is not available")
        }
        guard !writing || access.write else {
            throw CalendarError.refused("changing the calendar is not available")
        }
        // Deleting needs the user's own message to have asked for it.
        if (tool == "calendar_delete_event" && access.deletes == .none)
            || (tool == "calendar_delete_calendar" && access.deletes != .all) {
            throw CalendarError.refused("deleting was not asked for in the user's message. Ask them to say plainly what to delete")
        }

        let refs = self.refs
        let work: @Sendable () async throws -> CalendarToolOutcome
        func key() throws -> String {
            guard let key = refs.key(for: arguments["event"] ?? "") else {
                throw CalendarError.refused("that event id is not known. Read the calendar for that day again and use the id shown there")
            }
            return key
        }
        func name(_ argument: String) throws -> String {
            let value = CalendarFormatter.clean(arguments[argument] ?? "")
            guard !value.isEmpty else { throw CalendarError.refused("the calendar needs a name") }
            return value
        }
        let future = arguments["scope"] == "future"
        switch tool {
        case "calendar_events":
            let range = try CalendarFormatter.range(start: arguments["start"] ?? "", end: arguments["end"] ?? "")
            let label = CalendarTools.summary(start: arguments["start"] ?? "", end: arguments["end"] ?? "")
            let search = arguments["search"] ?? ""
            work = {
                let events = CalendarFormatter.filter(try await calendar.events(from: range.0, to: range.1), search: search)
                return .read(content: CalendarFormatter.text(for: events, ref: { refs.ref(for: $0.key) }),
                             summary: label, events: events.count)
            }
        case "calendar_event_details":
            let key = try key()
            work = {
                .read(content: CalendarFormatter.details(try await calendar.snapshot(key: key)),
                      summary: "one event's details", events: -1)
            }
        case "calendar_list":
            work = {
                .read(content: CalendarFormatter.text(for: try await calendar.calendars()),
                      summary: "your list of calendars", events: -1)
            }
        case "calendar_create_event":
            let change = CalendarChange.create(try EventDraft.parse(arguments))
            let namesCalendar = arguments["calendar"] != nil
            work = {
                if namesCalendar { try change.check(against: try await calendar.calendars()) }
                return .proposal(change)
            }
        case "calendar_update_event":
            let key = try key()
            work = {
                let original = try await calendar.snapshot(key: key)
                let after = try original.draft.applying(arguments)
                let change = CalendarChange.update(original: original, after: after, future: future && original.recurring)
                try change.check(against: try await calendar.calendars())
                return .proposal(change)
            }
        case "calendar_delete_event":
            let key = try key()
            work = {
                let snapshot = try await calendar.snapshot(key: key)
                let change = CalendarChange.delete(snapshot, future: future && snapshot.recurring)
                try change.check(against: try await calendar.calendars())
                return .proposal(change)
            }
        case "calendar_create_calendar", "calendar_rename_calendar", "calendar_delete_calendar":
            let change: CalendarChange
            switch tool {
            case "calendar_create_calendar": change = .createCalendar(name: try name("name"))
            case "calendar_rename_calendar": change = .renameCalendar(from: try name("name"), to: try name("new_name"))
            default: change = .deleteCalendar(name: try name("name"))
            }
            work = {
                let list = try await calendar.calendars()
                try change.check(against: list)
                // The preview says which account is involved and how much would go.
                switch change {
                case .createCalendar(let name, _):
                    return .proposal(.createCalendar(name: name,
                                                     account: try CalendarAccounts.choose(arguments["account"], from: list)))
                case .deleteCalendar(let name, _, _, _):
                    let info = list.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
                    let count = try? await calendar.eventCount(calendarNamed: info?.name ?? name)
                    return .proposal(.deleteCalendar(name: info?.name ?? name, account: info?.account ?? "",
                                                     events: count ?? nil, isDefault: info?.isDefault ?? false))
                default:
                    return .proposal(change)
                }
            }
        default:
            throw CalendarError.refused("that is not something OMNIS can do with the calendar")
        }
        return work
    }

    /// "18 Nov" or "18 Nov to 20 Nov", for the line shown under the answer.
    public static func summary(start: String, end: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        let shown = DateFormatter()
        shown.locale = Locale(identifier: "en_GB")
        shown.dateFormat = "d MMM"
        guard let first = parser.date(from: start), let last = parser.date(from: end) else { return "calendar" }
        let (from, to) = first <= last ? (first, last) : (last, first)
        return from == to ? shown.string(from: from) : "\(shown.string(from: from)) to \(shown.string(from: to))"
    }
}
