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

    public var errorDescription: String? {
        switch self {
        case .notAllowed:
            return "OMNIS has not been allowed to read your calendar. You can allow it in System Settings, under Privacy & Security, Calendars"
        case .badDates: return "the dates asked for were not valid"
        case .unavailable(let why): return "the calendar could not be read (\(why))"
        }
    }
}

/// Anything that can read calendar events. Reading only: nothing here can add or change an event.
public protocol CalendarReading: Sendable {
    func events(from start: Date, to end: Date) async throws -> [CalendarEvent]
}

/// Reads the Mac's calendars through EventKit, Apple's own interface. The
/// first use makes macOS ask the user for permission; nothing is read before
/// that is given.
public final class EventKitCalendar: CalendarReading, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    public func events(from start: Date, to end: Date) async throws -> [CalendarEvent] {
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
        let day = DateFormatter()
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.locale = locale
        day.dateFormat = "EEE d MMM"
        let time = DateFormatter()
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.locale = locale
        time.dateFormat = "HH:mm"

        var lines: [String] = []
        for event in sorted.prefix(maxEvents) {
            var line: String
            // An all-day event ends at the start of the following day, so its
            // last day is the one just before its end. Comparing days, not
            // hours, keeps this right when the clocks change.
            let lastMoment = event.allDay ? event.end.addingTimeInterval(-1) : event.end
            let sameDay = calendar.isDate(event.start, inSameDayAs: lastMoment)
            if event.allDay {
                line = sameDay ? "\(day.string(from: event.start)), all day"
                    : "\(day.string(from: event.start)) to \(day.string(from: event.end.addingTimeInterval(-1))), all day"
            } else if sameDay {
                line = "\(day.string(from: event.start)), \(time.string(from: event.start)) to \(time.string(from: event.end))"
            } else {
                line = "\(day.string(from: event.start)) \(time.string(from: event.start)) to \(day.string(from: event.end)) \(time.string(from: event.end))"
            }
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
        ].joined(separator: "|"),
        options: [.caseInsensitive]
    )

    public static func mentionsCalendar(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
