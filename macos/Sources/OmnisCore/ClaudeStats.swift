import Foundation

/// The span of time the usage statistics cover.
public enum StatsRange: String, CaseIterable, Sendable, Identifiable {
    case all, week, month

    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .all: return "All time"
        case .week: return "Last 7 days"
        case .month: return "Last 30 days"
        }
    }
}

/// The user's Claude Code usage, read from the summary Claude Code keeps for
/// its own statistics screen (`~/.claude/stats-cache.json`).
///
/// That file holds totals only: counts per day and tokens per model. It has
/// no conversation text. OMNIS only reads it. Its layout belongs to Claude
/// Code and may change, so everything here is read defensively and anything
/// missing simply does not appear.
public struct ClaudeStats: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let date: Date
        public var messages = 0
        public var sessions = 0
        public var toolCalls = 0
        public var tokens: [String: Int] = [:]
    }

    public struct ModelTotal: Equatable, Sendable {
        public var input = 0
        public var output = 0
        public var cacheRead = 0
        public var cacheWrite = 0
        public var all: Int { input + output + cacheRead + cacheWrite }
    }

    /// One entry per day that has any record, oldest first.
    public var days: [Day]
    public var modelTotals: [String: ModelTotal]
    public var totalSessions: Int
    public var longestSessionSeconds: Int?
    public var hourCounts: [Int: Int]
    /// The last day the summary was brought up to date.
    public var computed: Date?

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/stats-cache.json")
    }

    private static func dayParser(_ calendar: Calendar) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }

    public static func load(from url: URL = defaultURL, calendar: Calendar = .current) -> ClaudeStats? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int, size < 8_000_000, let data = try? Data(contentsOf: url) else { return nil }
        return parse(data, calendar: calendar)
    }

    static func parse(_ data: Data, calendar: Calendar = .current) -> ClaudeStats? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let parser = dayParser(calendar)
        func number(_ value: Any?) -> Int { max(0, (value as? NSNumber)?.intValue ?? 0) }
        func day(_ value: Any?) -> Date? { (value as? String).flatMap { parser.date(from: String($0.prefix(10))) } }

        var byDate: [Date: Day] = [:]
        for entry in (root["dailyActivity"] as? [[String: Any]]) ?? [] {
            guard let date = day(entry["date"]) else { continue }
            var record = byDate[date] ?? Day(date: date)
            record.messages = number(entry["messageCount"])
            record.sessions = number(entry["sessionCount"])
            record.toolCalls = number(entry["toolCallCount"])
            byDate[date] = record
        }
        for entry in (root["dailyModelTokens"] as? [[String: Any]]) ?? [] {
            guard let date = day(entry["date"]), let tokens = entry["tokensByModel"] as? [String: Any] else { continue }
            var record = byDate[date] ?? Day(date: date)
            for (model, count) in tokens where model.count <= 80 { record.tokens[model] = number(count) }
            byDate[date] = record
        }
        var totals: [String: ModelTotal] = [:]
        for (model, value) in (root["modelUsage"] as? [String: Any]) ?? [:] where model.count <= 80 {
            guard let usage = value as? [String: Any] else { continue }
            totals[model] = ModelTotal(input: number(usage["inputTokens"]), output: number(usage["outputTokens"]),
                                       cacheRead: number(usage["cacheReadInputTokens"]),
                                       cacheWrite: number(usage["cacheCreationInputTokens"]))
        }
        var hours: [Int: Int] = [:]
        for (hour, count) in (root["hourCounts"] as? [String: Any]) ?? [:] {
            if let hour = Int(hour), (0..<24).contains(hour) { hours[hour] = number(count) }
        }
        let longest = (root["longestSession"] as? [String: Any]).map { number($0["duration"]) / 1000 }
        guard !byDate.isEmpty || !totals.isEmpty else { return nil }
        return ClaudeStats(days: byDate.values.sorted { $0.date < $1.date }, modelTotals: totals,
                           totalSessions: number(root["totalSessions"]),
                           longestSessionSeconds: longest.flatMap { $0 > 0 ? $0 : nil },
                           hourCounts: hours, computed: day(root["lastComputedDate"]))
    }

    // MARK: A summary for one span of time

    public struct Cell: Equatable, Sendable, Identifiable {
        public let date: Date
        public let messages: Int
        /// 0 for nothing, up to 4 for the busiest days of the span.
        public let level: Int
        public var id: Date { date }
    }

    public struct ModelShare: Equatable, Sendable, Identifiable {
        public let name: String
        public let percent: Int
        public var id: String { name }
    }

    public struct Summary: Equatable, Sendable {
        /// Every day of the span, oldest first, including days with nothing.
        public var cells: [Cell] = []
        public var tokens = 0
        public var favourite: String?
        public var models: [ModelShare] = []
        public var sessions = 0
        public var messages = 0
        public var toolCalls = 0
        public var activeDays = 0
        public var totalDays = 0
        public var mostActive: Cell?
        public var longestStreak = 0
        public var currentStreak = 0
        // The rest is known only for all time.
        public var longestSession: String?
        public var busiestHour: Int?
        public var breakdown: ModelTotal?
        /// How many novels' worth of text Claude has written, at about 120,000 tokens each.
        public var novelsWritten: Int?
    }

    /// "claude-opus-5-5" becomes "Opus 5.5".
    public static func modelName(_ id: String) -> String {
        var parts = id.split(separator: "-").map(String.init)
        if parts.first == "claude" { parts.removeFirst() }
        guard let family = parts.first else { return id }
        let version = parts.dropFirst().filter { Int($0) != nil && $0.count <= 2 }.joined(separator: ".")
        let name = family.prefix(1).uppercased() + family.dropFirst()
        return version.isEmpty ? name : "\(name) \(version)"
    }

    static func duration(_ seconds: Int) -> String {
        let days = seconds / 86_400, hours = (seconds % 86_400) / 3600, minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)d \(hours)h \(minutes)m" }
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(max(minutes, 1))m"
    }

    public func summary(_ range: StatsRange, now: Date = Date(), calendar: Calendar = .current) -> Summary {
        let today = calendar.startOfDay(for: now)
        let first: Date
        switch range {
        case .week: first = calendar.date(byAdding: .day, value: -6, to: today) ?? today
        case .month: first = calendar.date(byAdding: .day, value: -29, to: today) ?? today
        case .all:
            // Never more than a year of squares, however old the first record.
            let earliest = calendar.date(byAdding: .day, value: -370, to: today) ?? today
            first = max(days.first.map { calendar.startOfDay(for: $0.date) } ?? today, earliest)
        }
        let known = Dictionary(days.map { (calendar.startOfDay(for: $0.date), $0) }, uniquingKeysWith: { first, _ in first })
        var span: [Day] = []
        var cursor = first
        while cursor <= today {
            span.append(known[cursor] ?? Day(date: cursor))
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        var summary = Summary()
        let top = span.map(\.messages).max() ?? 0
        summary.cells = span.map { day in
            let level = day.messages == 0 || top == 0 ? 0 : min(4, 1 + Int((Double(day.messages) / Double(top) * 3).rounded(.down)))
            return Cell(date: day.date, messages: day.messages, level: level)
        }
        summary.totalDays = span.count
        summary.activeDays = span.filter { $0.messages > 0 }.count
        summary.messages = span.reduce(0) { $0 + $1.messages }
        summary.toolCalls = span.reduce(0) { $0 + $1.toolCalls }
        summary.sessions = range == .all ? max(totalSessions, span.reduce(0) { $0 + $1.sessions }) : span.reduce(0) { $0 + $1.sessions }
        summary.mostActive = summary.cells.filter { $0.messages > 0 }.max { ($0.messages, $1.date) < ($1.messages, $0.date) }

        var run = 0
        for cell in summary.cells {
            run = cell.messages > 0 ? run + 1 : 0
            summary.longestStreak = max(summary.longestStreak, run)
        }
        // A streak still counts today if today has not started yet.
        var recent = summary.cells
        if recent.last?.messages == 0 { recent.removeLast() }
        summary.currentStreak = recent.reversed().prefix { $0.messages > 0 }.count

        var perModel: [String: Int] = [:]
        for day in span { for (model, count) in day.tokens { perModel[model, default: 0] += count } }
        summary.tokens = perModel.values.reduce(0, +)
        let ranked = perModel.filter { $0.value > 0 }.sorted { ($0.value, $1.key) > ($1.value, $0.key) }
        summary.favourite = ranked.first.map { Self.modelName($0.key) }
        if summary.tokens > 0 {
            summary.models = ranked.prefix(3).map {
                ModelShare(name: Self.modelName($0.key), percent: Int((Double($0.value) / Double(summary.tokens) * 100).rounded()))
            }
        }

        if range == .all {
            summary.longestSession = longestSessionSeconds.map(Self.duration)
            summary.busiestHour = hourCounts.max { ($0.value, $1.key) < ($1.value, $0.key) }?.key
            if !modelTotals.isEmpty {
                var total = ModelTotal()
                for value in modelTotals.values {
                    total.input += value.input
                    total.output += value.output
                    total.cacheRead += value.cacheRead
                    total.cacheWrite += value.cacheWrite
                }
                summary.breakdown = total
                summary.novelsWritten = total.output >= 120_000 ? total.output / 120_000 : nil
                // With no per-day figures, fall back to the all-time totals for the favourite.
                if summary.favourite == nil {
                    summary.favourite = modelTotals.max { $0.value.all < $1.value.all }.map { Self.modelName($0.key) }
                }
            }
        }
        return summary
    }

    /// The days laid out like a calendar on its side: one column per week,
    /// Monday at the top. Days outside the span are nil.
    public static func weeks(_ cells: [Cell], calendar: Calendar = .current) -> [[Cell?]] {
        var columns: [[Cell?]] = []
        for cell in cells {
            // Monday is row 0. `weekday` is 1 for Sunday.
            let row = (calendar.component(.weekday, from: cell.date) + 5) % 7
            if columns.isEmpty || row == 0 { columns.append(Array(repeating: nil, count: 7)) }
            columns[columns.count - 1][row] = cell
        }
        return columns
    }

    /// For each week column, the short month name if a month starts in it.
    public static func monthLabels(_ weeks: [[Cell?]], calendar: Calendar = .current) -> [String] {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = "MMM"
        var last: Int?
        return weeks.map { week in
            guard let first = week.compactMap({ $0 }).first else { return "" }
            let month = calendar.component(.month, from: first.date)
            defer { last = month }
            return month == last ? "" : formatter.string(from: first.date)
        }
    }
}

extension DashboardData {
    /// "2.9b", "1.9M", "41k", "820".
    public static func compactLarge(_ count: Int) -> String {
        count >= 1_000_000_000 ? String(format: "%.1fb", Double(count) / 1_000_000_000) : compact(count)
    }
}
