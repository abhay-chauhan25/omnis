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

    public init(title: String, start: Date, end: Date, allDay: Bool = false, calendar: String, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.calendar = calendar
        self.location = location
    }
}

public enum CalendarError: Error, Equatable, LocalizedError {
    case notAllowed
    case badDates
    case unavailable(String)
    case badEvent(String)
    case noCalendar

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            return "OMNIS has not been allowed to read your calendar. You can allow it in System Settings, under Privacy & Security, Calendars"
        case .badDates: return "the dates asked for were not valid"
        case .unavailable(let why): return "the calendar could not be used (\(why))"
        case .badEvent(let why): return "the event could not be prepared: \(why)"
        case .noCalendar: return "there is no calendar that new events can be added to. Choose a default calendar in the Calendar app's settings"
        }
    }
}

/// Anything that can read calendar events. Reading only: nothing here can add or change an event.
public protocol CalendarReading: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

/// A new event that has been proposed but not saved.
public struct EventDraft: Equatable, Sendable {
    public let title: String
    public let start: Date
    /// For an all-day event, the first moment of the day after its last day.
    public let end: Date
    public let allDay: Bool
    public let location: String?

    public init(title: String, start: Date, end: Date, allDay: Bool = false, location: String? = nil) {
        self.title = title
        self.start = start
        self.end = end
        self.allDay = allDay
        self.location = location
    }

    public static let maxDays = 31

    /// Builds a draft from what the model asked for. Times are read as local
    /// times in the user's time zone. Anything that is not a clear, real
    /// date and time is refused.
    public static func parse(_ arguments: [String: String], calendar: Calendar = .current) throws -> EventDraft {
        let title = CalendarFormatter.clean(arguments["title"] ?? "")
        guard !title.isEmpty else { throw CalendarError.badEvent("it has no title") }
        let allDay = arguments["all_day"] == "true"
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.isLenient = false
        formatter.dateFormat = allDay ? "yyyy-MM-dd" : "yyyy-MM-dd'T'HH:mm"
        let length = allDay ? 10 : 16
        let startText = arguments["start"] ?? "", endText = arguments["end"] ?? ""
        guard startText.count == length, endText.count == length,
              let first = formatter.date(from: startText), let last = formatter.date(from: endText) else {
            throw CalendarError.badEvent("its date or time was not valid")
        }
        let start: Date, end: Date
        if allDay {
            start = calendar.startOfDay(for: first)
            guard last >= first,
                  let dayAfter = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: last)) else {
                throw CalendarError.badEvent("it ends before it starts")
            }
            end = dayAfter
        } else {
            guard last > first else { throw CalendarError.badEvent("it ends before it starts") }
            start = first
            end = last
        }
        guard let limit = calendar.date(byAdding: .day, value: maxDays + 1, to: start), end <= limit else {
            throw CalendarError.badEvent("it is longer than \(maxDays) days")
        }
        let place = CalendarFormatter.clean(arguments["location"] ?? "")
        return EventDraft(title: title, start: start, end: end, allDay: allDay, location: place.isEmpty ? nil : place)
    }

    /// When the event is, for the preview: "Wed 18 Nov, 13:00 to 14:00".
    /// The year is added when it is not this year, so a wrong year is seen.
    public func when(calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_GB"), now: Date = Date()) -> String {
        let otherYear = calendar.component(.year, from: start) != calendar.component(.year, from: now)
        return CalendarFormatter.when(start: start, end: end, allDay: allDay, calendar: calendar, locale: locale,
                                      showYear: otherYear)
    }

    /// One line describing the draft, in the same form as events read from the calendar.
    public func line(calendar: Calendar = .current) -> String {
        CalendarFormatter.text(for: [CalendarEvent(title: title, start: start, end: end, allDay: allDay,
                                                   calendar: "", location: location)], calendar: calendar)
    }
}

/// Anything that can add an event to the calendar. This is called only when
/// the user clicks to confirm a preview, never by the model.
public protocol CalendarWriting: Sendable {
    /// The name of the calendar a new event would go into.
    func defaultCalendarName() async throws -> String
    /// Saves the event and returns the name of the calendar it went into.
    func create(_ draft: EventDraft) async throws -> String
}

/// Reads the Mac's calendars through EventKit, Apple's own interface. The
/// first use makes macOS ask the user for permission; nothing is read before
/// that is given.
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

    private func targetCalendar() throws -> EKCalendar {
        guard let target = store.defaultCalendarForNewEvents, target.allowsContentModifications else {
            throw CalendarError.noCalendar
        }
        return target
    }

    public func defaultCalendarName() async throws -> String {
        try await ensureAccess()
        return try targetCalendar().title
    }

    /// The only place in OMNIS that changes the calendar. It adds one new
    /// event; it cannot change or remove an existing one.
    public func create(_ draft: EventDraft) async throws -> String {
        try await ensureAccess()
        let target = try targetCalendar()
        let event = EKEvent(eventStore: store)
        event.title = draft.title
        event.startDate = draft.start
        // EventKit wants an all-day event to end within its last day.
        event.endDate = draft.allDay ? draft.end.addingTimeInterval(-1) : draft.end
        event.isAllDay = draft.allDay
        event.location = draft.location
        event.calendar = target
        do {
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            throw CalendarError.unavailable(error.localizedDescription)
        }
        return target.title
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
                location: event.location
            )
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
    public static func text(for events: [CalendarEvent], calendar: Calendar = .current,
                            locale: Locale = Locale(identifier: "en_GB")) -> String {
        let sorted = events.sorted { ($0.start, $0.title) < ($1.start, $1.title) }
        var lines: [String] = []
        for event in sorted.prefix(maxEvents) {
            var line = when(start: event.start, end: event.end, allDay: event.allDay, calendar: calendar, locale: locale)
            let title = clean(event.title)
            line += ": \(title.isEmpty ? "(no title)" : title)"
            let name = clean(event.calendar)
            if !name.isEmpty { line += " (\(name))" }
            if let place = event.location.map(clean), !place.isEmpty { line += " at \(place)" }
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

    static func clean(_ text: String) -> String {
        // Invisible characters that reorder text on screen are removed too.
        let flat = text.unicodeScalars.filter { !(0x202A...0x202E).contains($0.value) && !(0x2066...0x2069).contains($0.value) }
            .map { scalar -> Character in
                CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) ? " " : Character(scalar)
            }
        let collapsed = String(flat).split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        return String(collapsed.prefix(maxFieldCharacters))
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
            // Asking for something to be put on the calendar.
            #"\b(add|create|make|set up|new) (an? |the )?(calendar )?event\b"#,
            #"\b(add|put|book|pencil|block)\b.{0,80}\b(today|tomorrow|tonight|monday|tuesday|wednesday|thursday|friday|saturday|sunday|next week|at \d{1,2}(:\d\d)? ?(am|pm)?)\b"#,
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    public static func mentionsCalendar(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
