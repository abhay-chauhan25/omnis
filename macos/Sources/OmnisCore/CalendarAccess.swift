import EventKit
import Foundation

/// One calendar event, reduced to what is passed to the model.
public struct CalendarEvent: Equatable, Sendable {
    public let title: String
    public let start: Date
    public let end: Date
    public let allDay: Bool
    public let calendar: String
    public let location: String?
    /// Identifies this event (and, for a repeating one, this day of it) to
    /// the calendar. Never shown to the model, which gets a short id instead.
    public let key: String
    public let repeats: Bool

    public init(title: String, start: Date, end: Date, allDay: Bool = false, calendar: String, location: String? = nil,
                key: String = "", repeats: Bool = false) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
        self.key = key
        self.repeats = repeats
    }
}

public enum CalendarError: Error, Equatable, LocalizedError {
    case notAllowed
    case badDates
    case unavailable(String)
    case badEvent(String)
    case noCalendar
    case gone
    case refused(String)

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            return "OMNIS has not been allowed to use your calendar. You can allow it in System Settings, under Privacy & Security, Calendars"
        case .badDates: return "the dates asked for were not valid"
        case .unavailable(let why): return "the calendar could not be used (\(why))"
        case .badEvent(let why): return "the event could not be prepared: \(why)"
        case .noCalendar: return "there is no calendar that new events can be added to. Choose a default calendar in the Calendar app's settings"
        case .gone: return "that event has changed or no longer exists. Read the calendar again"
        case .refused(let why): return why
        }
    }

    /// A fixed word for the audit log. Unlike the description, it never
    /// carries a calendar's name or anything else from the calendar.
    public var code: String {
        switch self {
        case .notAllowed: return "not_allowed"
        case .badDates: return "bad_dates"
        case .unavailable: return "unavailable"
        case .badEvent: return "bad_event"
        case .noCalendar: return "no_calendar"
        case .gone: return "gone"
        case .refused: return "refused"
        }
    }
}

/// How an event repeats. `custom` stands for a rule OMNIS can show but not
/// set, such as "every second Tuesday"; it is left untouched by changes.
public enum Repeat: String, Equatable, Sendable {
    case none, daily, weekly, monthly, yearly, custom
}

/// One of the user's calendars.
public struct CalendarInfo: Equatable, Sendable {
    public let name: String
    public let writable: Bool
    public let isDefault: Bool
    /// The account it belongs to, such as "iCloud".
    public let account: String

    public init(name: String, writable: Bool = true, isDefault: Bool = false, account: String = "") {
        self.name = name
        self.writable = writable
        self.isDefault = isDefault
        self.account = account
    }
}

/// An existing event with all its details, as it was when it was looked up.
public struct EventSnapshot: Equatable, Sendable {
    public let key: String
    /// Its details, with `calendarName` set to the calendar it is in.
    public let draft: EventDraft
    public let guests: [String]
    public let recurring: Bool
    /// True when it has more than one alert, or an alert at a fixed time.
    /// OMNIS shows only one alert, so it will not change the alerts of such an event.
    public let complexAlerts: Bool
    /// True when its notes are longer than OMNIS shows. It will not change them.
    public let longNotes: Bool

    public init(key: String, draft: EventDraft, guests: [String] = [], recurring: Bool = false,
                complexAlerts: Bool = false, longNotes: Bool = false) {
        self.key = key
        self.draft = draft
        self.guests = guests
        self.recurring = recurring
        self.complexAlerts = complexAlerts
        self.longNotes = longNotes
    }
}

/// Anything that can read the calendar. Nothing here can change it.
public protocol CalendarReading: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
    /// One event in full, by the key it was listed with.
    func snapshot(key: String) async throws -> EventSnapshot
    func calendars() async throws -> [CalendarInfo]
    /// How many events a calendar holds, as far as can be counted. Nil if unknown.
    func eventCount(calendarNamed name: String) async throws -> Int?
}

/// The details of an event: a new one being proposed, or an existing one.
public struct EventDraft: Equatable, Sendable {
    public let title: String
    public let start: Date
    /// For an all-day event, the first moment of the day after its last day.
    public let end: Date
    public let allDay: Bool
    public let location: String?
    public let notes: String?
    public let url: String?
    /// Nil means the default calendar.
    public let calendarName: String?
    /// Minutes before the start that an alert is shown. Nil means no alert.
    public let alertMinutes: Int?
    public let repeats: Repeat
    /// The last moment it repeats. Nil means it repeats with no end.
    public let repeatUntil: Date?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil,
                notes: String? = nil, url: String? = nil, calendarName: String? = nil, alertMinutes: Int? = nil,
                repeats: Repeat = .none, repeatUntil: Date? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
        self.notes = notes
        self.url = url
        self.calendarName = calendarName
        self.alertMinutes = alertMinutes
        self.repeats = repeats
        self.repeatUntil = repeatUntil
    }

    public static let maxDays = 31
    public static let maxNotesCharacters = 1000
    public static let maxAlertMinutes = 40_320   // four weeks

    private static func formatter(_ format: String, _ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        formatter.dateFormat = format
        return formatter
    }

    /// Reads "2026-11-18T13:00" or "2026-11-18" as a local time in the user's zone.
    private static func moment(_ text: String, _ calendar: Calendar) -> (date: Date, dateOnly: Bool)? {
        if text.count == 16, let date = formatter("yyyy-MM-dd'T'HH:mm", calendar).date(from: text) { return (date, false) }
        if text.count == 10, let date = formatter("yyyy-MM-dd", calendar).date(from: text) { return (date, true) }
        return nil
    }

    /// Builds a new event from what the model asked for. Times are read as
    /// local times in the user's time zone. Anything that is not a clear,
    /// real date and time is refused.
    public static func parse(_ arguments: [String: String], calendar: Calendar = .current) throws -> EventDraft {
        let title = CalendarFormatter.clean(arguments["title"] ?? "")
        guard !title.isEmpty else { throw CalendarError.badEvent("it has no title") }
        let allDay = arguments["all_day"] == "true"
        guard let first = moment(arguments["start"] ?? "", calendar), let last = moment(arguments["end"] ?? "", calendar),
              first.dateOnly == allDay, last.dateOnly == allDay else {
            throw CalendarError.badEvent("its date or time was not valid")
        }
        let start: Date, end: Date
        if allDay {
            start = calendar.startOfDay(for: first.date)
            guard last.date >= first.date,
                  let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last.date)) else {
                throw CalendarError.badEvent("it ends before it starts")
            }
            end = dayAfter
        } else {
            guard last.date > first.date else { throw CalendarError.badEvent("it ends before it starts") }
            start = first.date
            end = last.date
        }
        try checkLength(start, end, calendar)
        let place = CalendarFormatter.clean(arguments["location"] ?? "")
        let base = EventDraft(title: title, start: start, end: end, allDay: allDay, location: place.isEmpty ? nil : place)
        return try base.withExtras(arguments, calendar: calendar)
    }

    private static func checkLength(_ start: Date, _ end: Date, _ calendar: Calendar) throws {
        guard end > start else { throw CalendarError.badEvent("it ends before it starts") }
        guard let limit = calendar.date(byAdding: .day, value: maxDays + 1, to: start), end <= limit else {
            throw CalendarError.badEvent("it is longer than \(maxDays) days")
        }
    }

    /// The event as it would be after the changes the model asked for. Only
    /// the fields named in `arguments` change; an empty value removes a detail.
    public func applying(_ arguments: [String: String], calendar: Calendar = .current) throws -> EventDraft {
        var title = self.title
        if let wanted = arguments["title"].map(CalendarFormatter.clean), !wanted.isEmpty { title = wanted }
        let allDay = arguments["all_day"].map { $0 == "true" } ?? self.allDay
        var start = self.start, end = self.end
        let givenStart = try arguments["start"].map { text -> (date: Date, dateOnly: Bool) in
            guard let found = Self.moment(text, calendar) else { throw CalendarError.badEvent("its new start was not valid") }
            return found
        }
        let givenEnd = try arguments["end"].map { text -> (date: Date, dateOnly: Bool) in
            guard let found = Self.moment(text, calendar) else { throw CalendarError.badEvent("its new end was not valid") }
            return found
        }

        if allDay {
            let days = max(1, self.allDay ? (calendar.dateComponents([.day], from: self.start, to: self.end).day ?? 1) : 1)
            start = calendar.startOfDay(for: givenStart?.date ?? self.start)
            let lastDay = givenEnd.map { calendar.startOfDay(for: $0.date) }
            guard let newEnd = calendar.date(byAdding: .day, value: lastDay == nil ? days : 1, to: lastDay ?? start) else {
                throw CalendarError.badEvent("its new end was not valid")
            }
            end = newEnd
        } else {
            if let given = givenStart {
                if given.dateOnly {
                    // A new day with no time: keep the time of day it had.
                    guard !self.allDay else { throw CalendarError.badEvent("it needs a start time now that it is not all day") }
                    let time = calendar.dateComponents([.hour, .minute], from: self.start)
                    guard let moved = calendar.date(bySettingHour: time.hour ?? 0, minute: time.minute ?? 0, second: 0,
                                                    of: given.date) else {
                        throw CalendarError.badEvent("its new start was not valid")
                    }
                    start = moved
                } else {
                    start = given.date
                }
                // Moving the start keeps the length, unless a new end is given.
                end = start.addingTimeInterval(self.allDay ? 3600 : self.end.timeIntervalSince(self.start))
            } else if self.allDay {
                throw CalendarError.badEvent("it needs a start time now that it is not all day")
            }
            if let given = givenEnd {
                guard !given.dateOnly else { throw CalendarError.badEvent("its new end needs a time") }
                // Models often send the old end along with a new start. An end
                // that is not after the new start is ignored, and the length
                // is kept; the preview shows the result either way.
                if givenStart == nil || given.date > start { end = given.date }
            }
        }
        // An event that is already very long, or has no length, can still
        // have its other details changed.
        if start != self.start || end != self.end || allDay != self.allDay { try Self.checkLength(start, end, calendar) }

        var location = self.location
        if let wanted = arguments["location"].map(CalendarFormatter.clean) { location = wanted.isEmpty ? nil : wanted }
        let base = EventDraft(title: title, start: start, end: end, allDay: allDay, location: location, notes: notes,
                              url: url, calendarName: calendarName, alertMinutes: alertMinutes, repeats: repeats,
                              repeatUntil: repeatUntil)
        return try base.withExtras(arguments, calendar: calendar)
    }

    /// Notes, link, calendar, alert and repeat setting from the model's
    /// request, laid over what the event already has.
    private func withExtras(_ arguments: [String: String], calendar: Calendar) throws -> EventDraft {
        var notes = self.notes, url = self.url, calendarName = self.calendarName
        var alertMinutes = self.alertMinutes, repeats = self.repeats, repeatUntil = self.repeatUntil
        if let wanted = arguments["notes"].map(CalendarFormatter.cleanNotes) { notes = wanted.isEmpty ? nil : wanted }
        if let wanted = arguments["url"]?.trimmingCharacters(in: .whitespacesAndNewlines) {
            if wanted.isEmpty {
                url = nil
            } else {
                guard wanted.count <= 300, let parsed = URL(string: wanted), let scheme = parsed.scheme?.lowercased(),
                      scheme == "https" || scheme == "http", parsed.host != nil else {
                    throw CalendarError.badEvent("its link was not a web address")
                }
                url = wanted
            }
        }
        if let wanted = arguments["calendar"].map(CalendarFormatter.clean), !wanted.isEmpty { calendarName = wanted }
        if let text = arguments["alert_minutes"] {
            guard let minutes = Int(text), minutes == -1 || (0...Self.maxAlertMinutes).contains(minutes) else {
                throw CalendarError.badEvent("its alert time was not valid")
            }
            alertMinutes = minutes == -1 ? nil : minutes
        }
        if let text = arguments["repeat"] {
            guard let wanted = Repeat(rawValue: text), wanted != .custom else {
                throw CalendarError.badEvent("its repeat setting was not valid")
            }
            repeats = wanted
            repeatUntil = nil
        }
        if let text = arguments["repeat_until"] {
            guard repeats != .none, repeats != .custom, let day = Self.moment(text, calendar), day.dateOnly,
                  let after = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: day.date)),
                  after > start else {
                throw CalendarError.badEvent("its last repeat day was not valid")
            }
            repeatUntil = after.addingTimeInterval(-1)
        }
        return EventDraft(title: title, start: start, end: end, allDay: allDay, location: location, notes: notes, url: url,
                          calendarName: calendarName, alertMinutes: alertMinutes, repeats: repeats, repeatUntil: repeatUntil)
    }

    /// When the event is, for the preview: "Wed 18 Nov, 13:00 to 14:00".
    /// The year is added when it is not this year, so a wrong year is seen.
    public func when(calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB"), now: Date = Date()) -> String {
        let otherYear = calendar.component(.year, from: start) != calendar.component(.year, from: now)
        return CalendarFormatter.when(start: start, end: end, allDay: allDay, calendar: calendar, locale: locale,
                                      showYear: otherYear)
    }

    /// One line describing the event, in the same form as events read from the calendar.
    public func line(calendar: Calendar = .current) -> String {
        CalendarFormatter.text(for: [CalendarEvent(title: title, start: start, end: end, allDay: allDay,
                                                   calendar: "", location: location)], calendar: calendar)
    }

    public var alertText: String {
        guard let minutes = alertMinutes else { return "none" }
        if minutes == 0 { return "at the start" }
        if minutes % 1440 == 0 { return minutes == 1440 ? "1 day before" : "\(minutes / 1440) days before" }
        if minutes % 60 == 0 { return minutes == 60 ? "1 hour before" : "\(minutes / 60) hours before" }
        return minutes == 1 ? "1 minute before" : "\(minutes) minutes before"
    }

    public func repeatText(calendar: Calendar = .current) -> String {
        let name: String
        switch repeats {
        case .none: return "does not repeat"
        case .custom: name = "on a custom pattern"
        default: name = repeats.rawValue
        }
        guard let until = repeatUntil else { return name }
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = Locale(identifier: "en_GB")
        day.dateFormat = "d MMM yyyy"
        return "\(name) until \(day.string(from: until))"
    }
}

/// Chooses the account for a new calendar.
public enum CalendarAccounts {
    /// The accounts that hold calendars the user can change, in a steady order.
    public static func names(in calendars: [CalendarInfo]) -> [String] {
        var seen: [String] = []
        for info in calendars where info.writable && !info.account.isEmpty
            && !seen.contains(where: { $0.caseInsensitiveCompare(info.account) == .orderedSame }) {
            seen.append(info.account)
        }
        return seen
    }

    /// The account the user named, or the best one to use if they named none.
    /// iCloud comes first: accounts such as Google do not let a Mac add calendars.
    public static func choose(_ wanted: String?, from calendars: [CalendarInfo]) throws -> String {
        let accounts = names(in: calendars)
        let listed = accounts.isEmpty ? "" : " The accounts are: " + accounts.joined(separator: ", ") + "."
        if let wanted = wanted?.trimmingCharacters(in: .whitespaces), !wanted.isEmpty {
            let exact = accounts.filter { $0.caseInsensitiveCompare(wanted) == .orderedSame }
            let loose = accounts.filter { $0.localizedCaseInsensitiveContains(wanted) || wanted.localizedCaseInsensitiveContains($0) }
            if let only = exact.first ?? (loose.count == 1 ? loose.first : nil) { return only }
            throw CalendarError.refused("there is no calendar account called \"\(wanted)\".\(listed)")
        }
        if let icloud = accounts.first(where: { $0.localizedCaseInsensitiveContains("icloud") }) { return icloud }
        if let local = accounts.first(where: { $0.localizedCaseInsensitiveContains("on my mac") }) { return local }
        if let standard = calendars.first(where: \.isDefault)?.account, !standard.isEmpty { return standard }
        // No account known: the calendar app's own default is used.
        return accounts.first ?? ""
    }
}

/// One line of a preview: what, and its value.
public struct ChangeRow: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// One change to the calendar, prepared for the user to confirm. Nothing in
/// this type does anything: it only describes.
public enum CalendarChange: Equatable, Sendable {
    case create(EventDraft)
    /// `future` applies to a repeating event: this day and all later ones.
    case update(original: EventSnapshot, after: EventDraft, future: Bool)
    case delete(EventSnapshot, future: Bool)
    case createCalendar(name: String, account: String = "")
    case renameCalendar(from: String, to: String)
    /// `events` is how many events it holds, where that could be counted.
    case deleteCalendar(name: String, account: String = "", events: Int? = nil, isDefault: Bool = false)

    /// A short word for the audit log. It carries no details of the change.
    public var kind: String {
        switch self {
        case .create: return "create_event"
        case .update: return "update_event"
        case .delete: return "delete_event"
        case .createCalendar: return "create_calendar"
        case .renameCalendar: return "rename_calendar"
        case .deleteCalendar: return "delete_calendar"
        }
    }

    public var heading: String {
        switch self {
        case .create: return "New event"
        case .update: return "Change event"
        case .delete: return "Delete event"
        case .createCalendar: return "New calendar"
        case .renameCalendar: return "Rename calendar"
        case .deleteCalendar: return "Delete calendar"
        }
    }

    /// The event's title or the calendar's name.
    public var title: String {
        switch self {
        case .create(let draft): return draft.title
        case .update(let original, _, _): return original.draft.title
        case .delete(let snapshot, _): return snapshot.draft.title
        case .createCalendar(let name, _): return name
        case .deleteCalendar(let name, _, _, _): return name
        case .renameCalendar(let from, _): return from
        }
    }

    public var confirmLabel: String {
        switch self {
        case .create: return "Add to Calendar"
        case .update: return "Change Event"
        case .delete: return "Delete Event"
        case .createCalendar: return "Create Calendar"
        case .renameCalendar: return "Rename Calendar"
        case .deleteCalendar: return "Delete Calendar"
        }
    }

    public var declineLabel: String {
        switch self {
        case .create, .createCalendar: return "Don't Add"
        case .update, .renameCalendar: return "Don't Change"
        case .delete, .deleteCalendar: return "Don't Delete"
        }
    }

    public var isDestructive: Bool {
        switch self {
        case .delete, .deleteCalendar: return true
        default: return false
        }
    }

    public var warning: String? {
        switch self {
        case .delete(let snapshot, let future):
            if snapshot.recurring && future { return "Deletes this day and every later repeat. This cannot be undone." }
            return "This cannot be undone."
        case .deleteCalendar(_, let account, _, let isDefault):
            return "Deletes this calendar and every event in it"
                + (account.isEmpty ? "" : ", on every device that uses \(account)")
                + ". This cannot be undone."
                + (isDefault ? " It is your default calendar for new events." : "")
        default: return nil
        }
    }

    /// The start of the event as it would be afterwards, if this is about one.
    public var resultingStart: Date? {
        switch self {
        case .create(let draft): return draft.start
        case .update(_, let after, _): return after.start
        default: return nil
        }
    }

    /// Changing or deleting an event with guests can send them a notice.
    private static func guests(_ snapshot: EventSnapshot) -> [ChangeRow] {
        guard !snapshot.guests.isEmpty else { return [] }
        let count = snapshot.guests.count == 1 ? "1 guest" : "\(snapshot.guests.count) guests"
        return [ChangeRow("Guests", "\(count), who may be told about this")]
    }

    private static func scope(_ future: Bool) -> ChangeRow {
        ChangeRow("Applies to", future ? "this day and all later repeats" : "this day only")
    }

    private static func details(_ draft: EventDraft, calendar: Calendar, now: Date) -> [ChangeRow] {
        var rows = [ChangeRow("When", draft.when(calendar: calendar, now: now))]
        if let place = draft.location { rows.append(ChangeRow("Place", place)) }
        if let name = draft.calendarName { rows.append(ChangeRow("Calendar", name)) }
        if draft.alertMinutes != nil { rows.append(ChangeRow("Alert", draft.alertText)) }
        if draft.repeats != .none { rows.append(ChangeRow("Repeats", draft.repeatText(calendar: calendar))) }
        if let link = draft.url { rows.append(ChangeRow("Link", link)) }
        if let notes = draft.notes { rows.append(ChangeRow("Notes", notes)) }
        return rows
    }

    /// Everything the change would do, line by line. For a change to an
    /// event, each line shows the old value and the new one.
    public func rows(calendar: Calendar = .current, now: Date = Date()) -> [ChangeRow] {
        switch self {
        case .create(let draft):
            return Self.details(draft, calendar: calendar, now: now)
        case .delete(let snapshot, let future):
            var rows = Self.details(snapshot.draft, calendar: calendar, now: now).filter { ["When", "Place", "Calendar", "Repeats"].contains($0.label) }
            rows += Self.guests(snapshot)
            if snapshot.recurring { rows.append(Self.scope(future)) }
            return rows
        case .update(let original, let after, let future):
            let before = original.draft
            var rows: [ChangeRow] = []
            func changed(_ label: String, _ old: String, _ new: String) { rows.append(ChangeRow(label, "\(old) → \(new)")) }
            if before.title != after.title { changed("Title", before.title, after.title) }
            if before.start != after.start || before.end != after.end || before.allDay != after.allDay {
                changed("When", before.when(calendar: calendar, now: now), after.when(calendar: calendar, now: now))
            } else {
                rows.append(ChangeRow("When", before.when(calendar: calendar, now: now)))
            }
            if before.location != after.location { changed("Place", before.location ?? "none", after.location ?? "none") }
            if before.calendarName != after.calendarName {
                changed("Calendar", before.calendarName ?? "default", after.calendarName ?? "default")
            }
            if before.alertMinutes != after.alertMinutes { changed("Alert", before.alertText, after.alertText) }
            if before.repeats != after.repeats || before.repeatUntil != after.repeatUntil {
                changed("Repeats", before.repeatText(calendar: calendar), after.repeatText(calendar: calendar))
            }
            if before.url != after.url { changed("Link", before.url ?? "none", after.url ?? "none") }
            if before.notes != after.notes { changed("Notes", before.notes ?? "none", after.notes ?? "none") }
            rows += Self.guests(original)
            if original.recurring { rows.append(Self.scope(future)) }
            return rows
        case .createCalendar(_, let account):
            return account.isEmpty ? [] : [ChangeRow("Account", account)]
        case .renameCalendar(_, let to):
            return [ChangeRow("New name", to)]
        case .deleteCalendar(_, let account, let events, _):
            var rows: [ChangeRow] = []
            if !account.isEmpty { rows.append(ChangeRow("Account", account)) }
            if let events {
                rows.append(ChangeRow("Events", events == 1 ? "1 event will be deleted" : "\(events) events will be deleted"))
            }
            return rows
        }
    }

    /// One line for the model to read in later turns.
    public func line(calendar: Calendar = .current) -> String {
        switch self {
        case .create(let draft): return "new event \(draft.line(calendar: calendar))"
        case .update(let original, let after, _):
            return "change \(original.draft.line(calendar: calendar)) to \(after.line(calendar: calendar))"
        case .delete(let snapshot, _): return "delete \(snapshot.draft.line(calendar: calendar))"
        case .createCalendar(let name, _): return "new calendar \"\(name)\""
        case .renameCalendar(let from, let to): return "rename calendar \"\(from)\" to \"\(to)\""
        case .deleteCalendar(let name, _, _, _): return "delete calendar \"\(name)\" and all its events"
        }
    }

    /// Checks the calendars a change names against the ones that exist, so a
    /// preview is never shown for something that cannot be done.
    public func check(against calendars: [CalendarInfo]) throws {
        func matching(_ name: String) -> [CalendarInfo] {
            calendars.filter { $0.name.caseInsensitiveCompare(name) == .orderedSame }
        }
        func existing(_ name: String) throws -> CalendarInfo {
            let found = matching(name)
            guard let only = found.first else { throw CalendarError.refused("there is no calendar called \"\(name)\"") }
            guard found.count == 1 else { throw CalendarError.refused("more than one calendar is called \"\(name)\"") }
            guard only.writable else { throw CalendarError.refused("the calendar \"\(name)\" cannot be changed") }
            return only
        }
        func unused(_ name: String) throws {
            guard !name.isEmpty else { throw CalendarError.refused("the calendar needs a name") }
            guard matching(name).isEmpty else { throw CalendarError.refused("there is already a calendar called \"\(name)\"") }
        }
        switch self {
        case .create(let draft):
            if let name = draft.calendarName { _ = try existing(name) }
        case .update(let original, let after, let future):
            let before = original.draft
            if after == before { throw CalendarError.refused("that would not change anything about the event") }
            // Details OMNIS cannot show in full are never rewritten.
            if original.complexAlerts && after.alertMinutes != before.alertMinutes {
                throw CalendarError.refused("that event has more than one alert, or an alert at a fixed time. Change its alerts in the Calendar app")
            }
            if original.longNotes && after.notes != before.notes {
                throw CalendarError.refused("that event's notes are too long to change here. Change them in the Calendar app")
            }
            let repeatChanges = after.repeats != before.repeats || after.repeatUntil != before.repeatUntil
            if repeatChanges && before.repeats == .custom {
                throw CalendarError.refused("that event repeats on a pattern OMNIS cannot set. Change how it repeats in the Calendar app")
            }
            if repeatChanges && original.recurring && !future {
                throw CalendarError.refused("how an event repeats can only be changed for this day and all later ones together. Ask the user whether that is what they want, then use scope future")
            }
            if let name = after.calendarName, name != original.draft.calendarName { _ = try existing(name) }
            if let name = original.draft.calendarName, let home = matching(name).first, !home.writable {
                throw CalendarError.refused("that event is in the calendar \"\(name)\", which cannot be changed")
            }
        case .delete(let snapshot, _):
            if let name = snapshot.draft.calendarName, let home = matching(name).first, !home.writable {
                throw CalendarError.refused("that event is in the calendar \"\(name)\", which cannot be changed")
            }
        case .createCalendar(let name, _):
            try unused(name)
        case .renameCalendar(let from, let to):
            _ = try existing(from)
            try unused(to)
        case .deleteCalendar(let name, _, _, _):
            _ = try existing(name)
        }
    }
}

/// How far deleting may go for one question.
public enum DeleteLevel: String, Equatable, Sendable {
    case none, events, all
}

/// Which calendar changes the model may prepare for one message.
public struct ChangeOffer: Equatable, Sendable {
    public let changes: Bool
    public let deletes: DeleteLevel

    public init(changes: Bool = false, deletes: DeleteLevel = .none) {
        self.changes = changes
        self.deletes = deletes
    }
}

/// Anything that can change the calendar. This is called only when the user
/// clicks to confirm a preview, never by the model.
public protocol CalendarWriting: Sendable {
    /// The name of the calendar a new event would go into.
    func defaultCalendarName() async throws -> String
    /// Carries out one confirmed change. Returns a few words on what was done.
    func apply(_ change: CalendarChange) async throws -> String
}

/// Short ids such as "e3" that stand for events when talking to the model.
/// The model never sees the calendar's own identifiers, and an id it makes
/// up matches nothing.
public final class EventRefs: @unchecked Sendable {
    private let lock = NSLock()
    private var refs: [String: String] = [:]
    private var keys: [String: String] = [:]
    private var next = 1

    public init() {}

    public func ref(for key: String) -> String {
        lock.withLock {
            if let known = refs[key] { return known }
            if refs.count >= 5000 { refs.removeAll(); keys.removeAll() }
            let ref = "e\(next)"
            next += 1
            refs[key] = ref
            keys[ref] = key
            return ref
        }
    }

    public func key(for ref: String) -> String? {
        lock.withLock { keys[ref.lowercased()] }
    }
}

/// The Mac's calendars through EventKit, Apple's own interface. The first use
/// makes macOS ask the user for permission; nothing happens before that is given.
public final class EventKitCalendar: CalendarReading, CalendarWriting, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess:
            break
        case .notDetermined:
            let granted: Bool
            do {
                granted = try await store.requestFullAccessToEvents()
            } catch {
                throw CalendarError.unavailable(error.localizedDescription)
            }
            guard granted else { throw CalendarError.notAllowed }
        default:
            throw CalendarError.notAllowed
        }
    }

    // MARK: Reading

    private static func key(for event: EKEvent) -> String {
        "\(event.eventIdentifier ?? "")|\(Int(event.startDate.timeIntervalSince1970))"
    }

    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
        try await ensureAccess()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).map { event in
            CalendarEvent(
                title: event.title ?? "",
                start: event.startDate,
                end: event.endDate,
                allDay: event.isAllDay,
                calendar: event.calendar?.title ?? "",
                location: event.location,
                key: Self.key(for: event),
                repeats: event.hasRecurrenceRules
            )
        }
    }

    /// Finds the event a key stands for, on the day it was listed for.
    private func find(_ key: String) throws -> EKEvent {
        let parts = key.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, let seconds = TimeInterval(parts[1]) else { throw CalendarError.gone }
        let start = Date(timeIntervalSince1970: seconds)
        let predicate = store.predicateForEvents(withStart: start.addingTimeInterval(-1), end: start.addingTimeInterval(1),
                                                 calendars: nil)
        let found = store.events(matching: predicate).first {
            $0.eventIdentifier == String(parts[0]) && abs($0.startDate.timeIntervalSince(start)) < 1
        }
        guard let found else { throw CalendarError.gone }
        return found
    }

    private func describe(_ event: EKEvent) -> EventSnapshot {
        let calendar = Calendar.current
        var end: Date = event.endDate
        if event.isAllDay {
            // EventKit ends an all-day event inside its last day.
            end = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: event.endDate)) ?? event.endDate
        }
        var repeats = Repeat.none
        var until: Date?
        if let rule = event.recurrenceRules?.first {
            // Anything beyond "every day, week, month or year, with or without
            // a last day" is called custom, and is then never rewritten.
            let days = rule.daysOfTheWeek ?? []
            let simple = rule.interval == 1 && days.count <= 1 && days.allSatisfy { $0.weekNumber == 0 }
                && (rule.setPositions?.isEmpty ?? true) && (rule.daysOfTheMonth?.isEmpty ?? true)
                && (rule.monthsOfTheYear?.isEmpty ?? true) && (rule.daysOfTheYear?.isEmpty ?? true)
                && (rule.weeksOfTheYear?.isEmpty ?? true) && (rule.recurrenceEnd?.occurrenceCount ?? 0) == 0
                && (event.recurrenceRules?.count ?? 0) == 1
            switch rule.frequency {
            case .daily: repeats = simple ? .daily : .custom
            case .weekly: repeats = simple ? .weekly : .custom
            case .monthly: repeats = simple ? .monthly : .custom
            case .yearly: repeats = simple ? .yearly : .custom
            @unknown default: repeats = .custom
            }
            until = rule.recurrenceEnd?.endDate
        }
        let alarms = event.alarms ?? []
        let alert = alarms.first.map { max(0, Int((-$0.relativeOffset / 60).rounded())) }
        let complexAlerts = alarms.count > 1 || alarms.contains { $0.absoluteDate != nil || $0.relativeOffset > 0 }
        // Text is cleaned for display. A detail that is not being changed is
        // never written back, so the calendar keeps its own copy as it was.
        func text(_ value: String?) -> String? {
            let cleaned = CalendarFormatter.clean(value ?? "")
            return cleaned.isEmpty ? nil : cleaned
        }
        let rawNotes = event.notes ?? ""
        let notes = CalendarFormatter.cleanNotes(rawNotes)
        let draft = EventDraft(
            title: CalendarFormatter.clean(event.title ?? ""), start: event.startDate, end: end, allDay: event.isAllDay,
            location: text(event.location), notes: notes.isEmpty ? nil : notes,
            url: text(event.url?.absoluteString), calendarName: text(event.calendar?.title), alertMinutes: alert,
            repeats: repeats, repeatUntil: until
        )
        return EventSnapshot(key: Self.key(for: event), draft: draft,
                             guests: (event.attendees ?? []).compactMap(\.name), recurring: event.hasRecurrenceRules,
                             complexAlerts: complexAlerts, longNotes: rawNotes.count > EventDraft.maxNotesCharacters)
    }

    public func snapshot(key: String) async throws -> EventSnapshot {
        try await ensureAccess()
        return describe(try find(key))
    }

    public func calendars() async throws -> [CalendarInfo] {
        try await ensureAccess()
        let standard = store.defaultCalendarForNewEvents?.calendarIdentifier
        return store.calendars(for: .event).map {
            CalendarInfo(name: $0.title, writable: $0.allowsContentModifications && !$0.isImmutable,
                         isDefault: $0.calendarIdentifier == standard, account: $0.source?.title ?? "")
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Counts the events in a calendar from two years back to two years
    /// ahead, which is as wide as one lookup can be.
    public func eventCount(calendarNamed name: String) async throws -> Int? {
        try await ensureAccess()
        let found = store.calendars(for: .event).filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        guard found.count == 1, let from = Calendar.current.date(byAdding: .year, value: -2, to: Date()),
              let to = Calendar.current.date(byAdding: .year, value: 2, to: Date()) else { return nil }
        return store.events(matching: store.predicateForEvents(withStart: from, end: to, calendars: found)).count
    }

    // MARK: Changing
    //
    // Everything below changes the calendar. It is reached only through
    // `apply`, which the app calls only when the user clicks to confirm.

    private func calendar(named name: String) throws -> EKCalendar {
        let found = store.calendars(for: .event).filter { $0.title.caseInsensitiveCompare(name) == .orderedSame }
        guard let only = found.first else { throw CalendarError.refused("there is no calendar called \"\(name)\"") }
        guard found.count == 1 else { throw CalendarError.refused("more than one calendar is called \"\(name)\"") }
        guard only.allowsContentModifications else { throw CalendarError.refused("the calendar \"\(name)\" cannot be changed") }
        return only
    }

    private func defaultCalendar() throws -> EKCalendar {
        guard let target = store.defaultCalendarForNewEvents, target.allowsContentModifications else {
            throw CalendarError.noCalendar
        }
        return target
    }

    public func defaultCalendarName() async throws -> String {
        try await ensureAccess()
        return try defaultCalendar().title
    }

    /// Writes onto `event` every detail of `wanted` that differs from `current`.
    /// Details that are not changing are never touched.
    private func write(_ wanted: EventDraft, onto event: EKEvent, replacing current: EventDraft?) throws {
        if current?.title != wanted.title { event.title = wanted.title }
        if current?.start != wanted.start || current?.end != wanted.end || current?.allDay != wanted.allDay {
            event.isAllDay = wanted.allDay
            event.startDate = wanted.start
            // EventKit wants an all-day event to end within its last day.
            event.endDate = wanted.allDay ? wanted.end.addingTimeInterval(-1) : wanted.end
        }
        if current?.location != wanted.location { event.location = wanted.location }
        if current?.notes != wanted.notes { event.notes = wanted.notes }
        if current?.url != wanted.url { event.url = wanted.url.flatMap { URL(string: $0) } }
        if current?.calendarName != wanted.calendarName || current == nil {
            event.calendar = try wanted.calendarName.map { try calendar(named: $0) } ?? defaultCalendar()
        }
        if current?.alertMinutes != wanted.alertMinutes {
            event.alarms = wanted.alertMinutes.map { [EKAlarm(relativeOffset: TimeInterval(-60 * $0))] }
        }
        if current?.repeats != wanted.repeats || current?.repeatUntil != wanted.repeatUntil {
            let frequency: EKRecurrenceFrequency?
            switch wanted.repeats {
            case .none: frequency = nil
            case .daily: frequency = .daily
            case .weekly: frequency = .weekly
            case .monthly: frequency = .monthly
            case .yearly: frequency = .yearly
            case .custom: return   // cannot be set; left as it is
            }
            event.recurrenceRules = frequency.map {
                [EKRecurrenceRule(recurrenceWith: $0, interval: 1, end: wanted.repeatUntil.map { EKRecurrenceEnd(end: $0) })]
            }
        }
    }

    public func apply(_ change: CalendarChange) async throws -> String {
        try await ensureAccess()
        do {
            switch change {
            case .create(let draft):
                let event = EKEvent(eventStore: store)
                try write(draft, onto: event, replacing: nil)
                try store.save(event, span: .thisEvent, commit: true)
                return "Added to \(event.calendar?.title ?? "your calendar")"
            case .update(let original, let after, let future):
                let event = try find(original.key)
                // If it has changed since the preview was made, the preview no
                // longer says what would happen, so nothing is done.
                guard describe(event).draft == original.draft else { throw CalendarError.gone }
                try write(after, onto: event, replacing: original.draft)
                try store.save(event, span: future ? .futureEvents : .thisEvent, commit: true)
                return "Changed"
            case .delete(let snapshot, let future):
                let event = try find(snapshot.key)
                guard describe(event).draft == snapshot.draft else { throw CalendarError.gone }
                try store.remove(event, span: future ? .futureEvents : .thisEvent, commit: true)
                return "Deleted"
            case .createCalendar(let name, let account):
                guard !store.calendars(for: .event).contains(where: { $0.title.caseInsensitiveCompare(name) == .orderedSame }) else {
                    throw CalendarError.refused("there is already a calendar called \"\(name)\"")
                }
                let created = EKCalendar(for: .event, eventStore: store)
                created.title = name
                // The account shown on the preview, and no other.
                let named = store.sources.first {
                    $0.title.caseInsensitiveCompare(account) == .orderedSame && !$0.calendars(for: .event).isEmpty
                }
                guard let source = account.isEmpty
                        ? (store.defaultCalendarForNewEvents?.source ?? store.sources.first(where: { $0.sourceType == .local }))
                        : named else {
                    throw CalendarError.refused("the account \"\(account)\" could not be found")
                }
                created.source = source
                do {
                    try store.saveCalendar(created, commit: true)
                } catch {
                    throw CalendarError.refused("\(source.title) would not add the calendar (\(error.localizedDescription)) Ask for it in another account, such as iCloud")
                }
                return "Calendar created in \(source.title)"
            case .renameCalendar(let from, let to):
                let target = try calendar(named: from)
                guard !target.isImmutable else { throw CalendarError.refused("the calendar \"\(from)\" cannot be renamed") }
                target.title = to
                try store.saveCalendar(target, commit: true)
                return "Renamed to \(to)"
            case .deleteCalendar(let name, _, _, _):
                let target = try calendar(named: name)
                guard !target.isImmutable else { throw CalendarError.refused("the calendar \"\(name)\" cannot be deleted") }
                try store.removeCalendar(target, commit: true)
                return "Calendar deleted"
            }
        } catch let error as CalendarError {
            throw error
        } catch {
            throw CalendarError.unavailable(error.localizedDescription)
        }
    }
}

/// Turns dates from the model into a range, and events into text for the model.
public enum CalendarFormatter {
    public static let maxEvents = 60
    public static let maxDays = 62
    static let maxFieldCharacters = 160

    /// Reads two "YYYY-MM-DD" dates as whole days in the user's time zone:
    /// from the first moment of the start day to the first moment after the end day.
    public static func range(start: String, end: String, calendar: Calendar = .current) throws -> (Date, Date) {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.isLenient = false
        guard start.count == 10, end.count == 10,
              var first = formatter.date(from: start), var last = formatter.date(from: end) else {
            throw CalendarError.badDates
        }
        if last < first { swap(&first, &last) }
        guard let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else {
            throw CalendarError.badDates
        }
        let from = calendar.startOfDay(for: first)
        guard let limit = calendar.date(byAdding: .day, value: maxDays + 1, to: from) else { throw CalendarError.badDates }
        return (from, min(dayAfter, limit))
    }

    /// One line per event, earliest first. Titles and places are flattened to
    /// a single line and shortened, since other people can write them.
    ///
    /// `ref` gives each event the short id the model uses to point at it.
    public static func text(for events: [CalendarEvent], calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "en_GB"),
                            ref: ((CalendarEvent) -> String)? = nil) -> String {
        let sorted = events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        var lines: [String] = []
        for event in sorted.prefix(maxEvents) {
            var line = when(start: event.start, end: event.end, allDay: event.allDay, calendar: calendar, locale: locale)
            let title = clean(event.title)
            line += ": \(title.isEmpty ? "(no title)" : title)"
            let name = clean(event.calendar)
            if !name.isEmpty { line += " (\(name))" }
            if let place = event.location.map(clean), !place.isEmpty { line += " at \(place)" }
            if event.repeats { line += " (repeats)" }
            if let ref, !event.key.isEmpty { line = "[\(ref(event))] " + line }
            lines.append(line)
        }
        if sorted.count > maxEvents {
            lines.append("(and \(sorted.count - maxEvents) more events not shown)")
        }
        return lines.joined(separator: "\n")
    }

    /// "Wed 18 Nov, 13:00 to 14:00", "Wed 18 Nov, all day", and so on.
    static func when(start: Date, end: Date, allDay: Bool, calendar: Calendar, locale: Locale,
                     showYear: Bool = false) -> String {
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = locale
        day.dateFormat = showYear ? "EEE d MMM yyyy" : "EEE d MMM"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.dateFormat = "HH:mm"
        // An all-day event ends at the start of the following day, so its
        // last day is the one just before its end. Comparing days, not
        // hours, keeps this right when the clocks change.
        let lastMoment = allDay ? end.addingTimeInterval(-1) : end
        let sameDay = calendar.isDate(start, inSameDayAs: lastMoment)
        if allDay {
            return sameDay ? "\(day.string(from: start)), all day"
                : "\(day.string(from: start)) to \(day.string(from: lastMoment)), all day"
        } else if sameDay {
            return "\(day.string(from: start)), \(time.string(from: start)) to \(time.string(from: end))"
        }
        return "\(day.string(from: start)) \(time.string(from: start)) to \(day.string(from: end)) \(time.string(from: end))"
    }

    /// Everything about one event, for the model.
    public static func details(_ snapshot: EventSnapshot, calendar: Calendar = .current) -> String {
        let draft = snapshot.draft
        var lines = [draft.line(calendar: calendar)]
        if let name = draft.calendarName { lines.append("Calendar: \(clean(name))") }
        lines.append("Alert: \(draft.alertText)")
        lines.append("Repeats: \(draft.repeatText(calendar: calendar))")
        if !snapshot.guests.isEmpty { lines.append("Guests: " + snapshot.guests.prefix(30).map(clean).joined(separator: ", ")) }
        if let link = draft.url { lines.append("Link: \(clean(link))") }
        if let notes = draft.notes { lines.append("Notes: \(cleanNotes(notes))") }
        return lines.joined(separator: "\n")
    }

    public static func text(for calendars: [CalendarInfo]) -> String {
        calendars.map { info in
            clean(info.name) + (info.account.isEmpty ? "" : " [account: \(clean(info.account))]")
                + (info.isDefault ? " (default for new events)" : "") + (info.writable ? "" : " (read-only)")
        }.joined(separator: "\n")
    }

    /// Only events whose title or place contains the text.
    public static func filter(_ events: [CalendarEvent], search: String) -> [CalendarEvent] {
        let wanted = search.trimmingCharacters(in: .whitespaces)
        guard !wanted.isEmpty else { return events }
        return events.filter {
            $0.title.localizedCaseInsensitiveContains(wanted) || ($0.location ?? "").localizedCaseInsensitiveContains(wanted)
        }
    }

    /// Notes keep their line breaks, but lose invisible and control characters.
    static func cleanNotes(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map(cleanLine).filter { !$0.isEmpty }
        return String(lines.joined(separator: "\n").prefix(EventDraft.maxNotesCharacters))
    }

    static func clean(_ text: String) -> String {
        String(cleanLine(text).prefix(maxFieldCharacters))
    }

    private static func cleanLine(_ text: String) -> String {
        // Invisible characters that reorder text on screen are removed too.
        let hidden: [ClosedRange<UInt32>] = [0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0x061C...0x061C, 0xFEFF...0xFEFF]
        let flat = text.unicodeScalars.filter { scalar in !hidden.contains { $0.contains(scalar.value) } }
            .map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
            }
        return String(flat).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
    }
}

/// Spots a question that is about the user's own schedule, so it is kept on
/// this Mac from the start and never offered to Claude.
public enum PersonalIntent {
    // Deliberately wide. A wrong match only means a public question is
    // answered by the local model. A missed one sends a question about your
    // own day to Claude, which cannot see your calendar and cannot help.
    private static let pattern = try! NSRegularExpression(
        pattern: [
            #"\b(calendar|schedule|agenda|appointments?|meetings?)\b"#,
            #"\bam i (free|busy|available)\b"#,
            #"\b(free|busy) (time|slot|today|tomorrow|tonight|this|next|on)\b"#,
            #"\bis (today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday) (free|busy|clear)\b"#,
            #"\b(do|did|will) i have\b"#,
            #"\bwhat (am i|are we) (doing|up to)\b"#,
            #"\bwhat do i have\b"#,
            #"\bwhat('s| is)? on (my |for )?(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|this |next |plate)"#,
            #"\banything (on|happening|planned|scheduled|going on)\b"#,
            #"\bmy (day|week|weekend|morning|afternoon|evening|plans|flight|call|dentist|doctor|next)\b"#,
            #"\bwhen('s| is) my\b"#,
            #"\bwhat time is my\b"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    public static func mentionsCalendar(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil || asksToChangeCalendar(text)
    }

    private static let days = "today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week"
    private static let months = "jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec"
    private static let addPattern = try! NSRegularExpression(
        pattern: #"\b(add|create|make|set up|put|book|pencil|block|schedule|plan|new)\b.{0,80}?\b(event|appointment|meeting|calendar|"#
            + days + #"|at \d{1,2}|\d{1,2}(st|nd|rd|th)? (of )?("# + months + #")|("# + months + #")[a-z]* \d{1,2})"#,
        options: [.caseInsensitive]
    )

    /// True when the user's own words ask for something to be put on the
    /// calendar. The tool that prepares events is offered to the model only
    /// then, so text in a file or a web page cannot bring up a preview.
    public static func asksToAddEvent(_ text: String) -> Bool {
        addPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let changeVerbs = "move|reschedule|change|rename|cancel|delete|remove|get rid of|update|edit|push|postpone|shift|clear|extend|shorten|bump|swap"
    private static let changePattern = try! NSRegularExpression(
        pattern: #"\b("# + changeVerbs + #")\b.{0,80}?\b(events?|appointments?|meetings?|calendars?|"# + days
            + #"|(at|to|from) \d{1,2}|\d{1,2}(st|nd|rd|th)? (of )?("# + months + #")|("# + months + #")[a-z]* \d{1,2})"#
            + #"|\b(cancel|reschedule|postpone) my\b"#,
        options: [.caseInsensitive]
    )
    private static let verbPattern = try! NSRegularExpression(pattern: #"\b("# + changeVerbs + #")\b"#, options: [.caseInsensitive])

    /// True when the user's own words ask for the calendar to be changed in
    /// any way: something added, moved, altered or deleted.
    public static func asksToChangeCalendar(_ text: String) -> Bool {
        asksToAddEvent(text) || changePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    private static let deletePattern = try! NSRegularExpression(
        pattern: #"\b(delete|cancel|remove|get rid of|clear|scrap|drop)\b"#, options: [.caseInsensitive])
    // "delete the Work calendar", but not "delete lunch from my calendar".
    private static let deleteCalendarPattern = try! NSRegularExpression(
        pattern: #"\b(delete|remove|get rid of)\b(?!.*\b(from|on|in|off) (my|the) calendar\b).{0,60}?\bcalendar\b"#,
        options: [.caseInsensitive])

    /// True when the user's own words ask for something to be deleted.
    public static func asksToDelete(_ text: String) -> Bool {
        deletePattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True when the user's own words ask for a whole calendar to be deleted.
    public static func asksToDeleteCalendar(_ text: String) -> Bool {
        deleteCalendarPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// True when the words include an instruction such as "move" or "delete"
    /// at all. Used only in a chat that is already about the calendar, where
    /// "delete the second one" needs no more than that.
    public static func hasChangeVerb(_ text: String) -> Bool {
        verbPattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
