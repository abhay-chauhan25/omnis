import Foundation

/// What the notch panel shows and where it sits, worked out apart from any
/// window so it can be checked without one.
public enum NotchData {
    /// "Dentist · 10:00 (in 40 min)", from today's agenda, or nil if nothing is left today.
    public static func nextEvent(in agenda: [DashboardData.AgendaRow], now: Date = Date()) -> String? {
        // The list may be a little old, so "next" is judged against the time now, not the time it was made.
        guard let next = agenda.first(where: { $0.start > now })
                ?? agenda.last(where: { $0.start <= now && now.timeIntervalSince($0.start) < 300 }) else { return nil }
        let minutes = Int((next.start.timeIntervalSince(now) / 60).rounded())
        let when: String
        if minutes <= 0 { when = "now" }
        else if minutes < 60 { when = "in \(minutes) min" }
        else if minutes < 600 { when = minutes % 60 == 0 ? "in \(minutes / 60) h" : "in \(minutes / 60) h \(minutes % 60) min" }
        else { when = "" }
        return "\(next.title) \u{00B7} \(next.time)" + (when.isEmpty ? "" : " (\(when))")
    }

    /// Titles of reminders due today or overdue, soonest first.
    public static func dueToday(_ reminders: [ReminderItem], now: Date = Date(), calendar: Calendar = .current, limit: Int = 3) -> [String] {
        guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) else { return [] }
        return reminders.filter { ($0.due ?? .distantFuture) < endOfDay }
            .sorted { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
            .prefix(limit).map { CalendarFormatter.clean($0.title) }
    }

    /// "Playing: Song by Artist." as the two parts the panel shows, or nil when nothing is playing.
    public static func track(from description: String) -> (title: String, playing: Bool)? {
        for (prefix, playing) in [("Playing: ", true), ("Paused on: ", false)] where description.hasPrefix(prefix) {
            var title = String(description.dropFirst(prefix.count))
            if title.hasSuffix(".") { title.removeLast() }
            // Only the last " by " divides the song from the artist: "Stand by Me by Ben E. King".
            if let divider = title.range(of: " by ", options: .backwards) { title.replaceSubrange(divider, with: " \u{2014} ") }
            return title.isEmpty ? nil : (title, playing)
        }
        return nil
    }
}

/// One day in the panel's strip of the week.
public struct NotchDay: Equatable, Sendable, Identifiable {
    public let date: Date
    /// "M", "T", "W".
    public let letter: String
    public let number: Int
    public let isToday: Bool
    public var id: Date { date }
}

public extension NotchData {
    /// The seven days centred on today: three before, today, three after.
    static func week(around now: Date = Date(), calendar: Calendar = .current) -> [NotchDay] {
        let today = calendar.startOfDay(for: now)
        let letters = calendar.veryShortWeekdaySymbols
        return (-3...3).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: today) else { return nil }
            let weekday = calendar.component(.weekday, from: date)
            return NotchDay(date: date, letter: letters[(weekday - 1) % letters.count], number: calendar.component(.day, from: date), isToday: offset == 0)
        }
    }

    /// "Nov", for the month the strip is centred on.
    static func month(of now: Date = Date(), calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMM"
        return formatter.string(from: now)
    }

    /// The next event as a title and a line under it: ("Dentist", "10:00 · in 40 min").
    static func nextEventParts(in agenda: [DashboardData.AgendaRow], now: Date = Date()) -> (title: String, when: String)? {
        guard let line = nextEvent(in: agenda, now: now), let divider = line.range(of: " \u{00B7} ") else { return nil }
        let rest = String(line[divider.upperBound...]).replacingOccurrences(of: " (", with: " \u{00B7} ").replacingOccurrences(of: ")", with: "")
        return (String(line[..<divider.lowerBound]), rest)
    }
}

/// Where the panel goes on the built-in screen. Sizes are in points, with the
/// origin at the bottom left, as macOS measures screens.
public struct NotchGeometry: Equatable, Sendable {
    public struct Rect: Equatable, Sendable {
        public var x, y, width, height: Double
        public init(x: Double, y: Double, width: Double, height: Double) {
            self.x = x; self.y = y; self.width = width; self.height = height
        }
    }

    public var screen: Rect
    /// The notch's own size. Zero width on a screen without one.
    public var notchWidth: Double
    public var notchHeight: Double

    public init(screen: Rect, notchWidth: Double, notchHeight: Double) {
        self.screen = screen
        self.notchWidth = notchWidth
        self.notchHeight = notchHeight
    }

    /// The strip that is always there: the notch plus a little either side, where the glow shows.
    public var resting: Rect {
        let width = max(notchWidth, 180) + 28
        let height = max(notchHeight, 24)
        return Rect(x: screen.x + (screen.width - width) / 2, y: screen.y + screen.height - height, width: width, height: height)
    }

    /// The open panel: hung from the top edge, centred on the notch, never wider than the screen.
    public func open(width: Double, height: Double) -> Rect {
        let wide = min(width, screen.width - 16)
        let tall = min(height + max(notchHeight, 24), screen.height - 40)
        return Rect(x: screen.x + (screen.width - wide) / 2, y: screen.y + screen.height - tall, width: wide, height: tall)
    }
}
