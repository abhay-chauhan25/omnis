import Foundation
import Testing
@testable import OmnisCore

@Suite struct ActivityLogTests {
    static let zone = TimeZone(identifier: "UTC")!
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    func record(_ time: String, _ action: String, _ outcome: String = "ok", target: String? = nil, detail: String? = nil,
                kind: String? = nil) -> AuditLog.Record {
        AuditLog.Record(time: time, action: action, kind: kind, target: target, outcome: outcome, detail: detail)
    }

    @Test func everyKindOfRecordReadsAsAPlainLine() {
        let rows = ActivityLog.rows(from: [
            record("2026-11-24T09:00:00Z", "launch", target: "VoyagerAI"),
            record("2026-11-24T09:01:00Z", "ask", detail: "model claude-haiku-5-5, route claude, in 12 tokens"),
            record("2026-11-24T09:02:00Z", "web_search", detail: "3 results"),
            record("2026-11-24T09:03:00Z", "search_consent", "asked", target: "web_search"),
            record("2026-11-24T09:04:00Z", "search_consent", "declined", detail: "for the rest of the chat"),
            record("2026-11-24T09:05:00Z", "tool_refused", "refused", target: "web_search", detail: "web search is switched off"),
            record("2026-11-24T09:06:00Z", "calendar_change", detail: "delete_event"),
            record("2026-11-24T09:07:00Z", "reminders_change", "declined", detail: "add"),
            record("2026-11-24T09:08:00Z", "service", detail: "Read your reminders"),
            record("2026-11-24T09:09:00Z", "tool_refused", "refused", target: "Bash", detail: "the advisor only reads files", kind: "advisor"),
            record("2026-11-24T09:10:00Z", "something_new", "ok", target: "thing"),
        ], calendar: Self.calendar)
        let lines = rows.reversed().map { "\($0.title) | \($0.outcome) | \($0.detail)" }
        #expect(lines == [
            "Opened VoyagerAI | done | ",
            "Answered a question | with Claude | model claude-haiku-5-5, route claude, in 12 tokens",
            "Searched the web | done | 3 results",
            "Asked whether this chat may search | asked you | the chat holds personal information",
            "Searches declined in a chat | you declined | for the rest of the chat",
            "Claude asked for a web search | refused | web search is switched off",
            "Delete an event | you confirmed | ",
            "Reminders: add | you declined | nothing was changed",
            "Read your reminders | done | ",
            "The advisor asked for Bash | refused | the advisor only reads files",
            "Something new | ok | thing",
        ])
        #expect(rows.first { $0.title == "Delete an event" }?.tone == .changed)
        #expect(rows.first { $0.outcome == "refused" }?.tone == .stopped)
    }

    @Test func filtersAndTypedWordsNarrowTheList() {
        let rows = ActivityLog.rows(from: [
            record("2026-11-24T09:00:00Z", "web_search", detail: "3 results"),
            record("2026-11-24T09:01:00Z", "calendar_read", detail: "2 events"),
            record("2026-11-24T09:02:00Z", "calendar_change", detail: "create_event"),
            record("2026-11-24T09:03:00Z", "calendar_change", "declined"),
            record("2026-11-24T09:04:00Z", "tool_refused", "refused", target: "Bash", detail: "not one of OMNIS's tools"),
            record("2026-11-24T09:05:00Z", "ask", "error", detail: "Claude stopped"),
        ], calendar: Self.calendar)
        let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
        func titles(_ filter: ActivityLog.Filter, _ text: String = "") -> [String] {
            ActivityLog.days(rows, filter: filter, matching: text, calendar: Self.calendar, now: now).flatMap(\.rows).map(\.title)
        }
        #expect(titles(.all).count == 6)
        #expect(titles(.searches) == ["Searched the web"])
        #expect(titles(.reads) == ["Read your calendar"])
        #expect(titles(.changes) == ["A calendar change", "Add an event"])
        #expect(titles(.refused) == ["Claude asked for Bash", "A calendar change"])
        #expect(titles(.all, "calendar READ") == ["Read your calendar"])
        #expect(titles(.all, "nothing like this").isEmpty)
        // A failure is not a refusal, but it is marked.
        #expect(rows.first { $0.title == "A question could not be answered" }?.tone == .stopped)
    }

    @Test func repeatsAreCountedAndDaysAreNamed() {
        let rows = ActivityLog.rows(from: [
            record("2026-11-20T08:00:00Z", "launch", target: "Safari"),
            record("2026-11-23T23:59:00Z", "calendar_read", detail: "14 events, for the dashboard"),
            record("2026-11-24T00:01:00Z", "calendar_read", detail: "14 events, for the dashboard"),
            record("2026-11-24T00:02:00Z", "calendar_read", detail: "14 events, for the dashboard"),
            record("not a time", "launch", target: "Broken"),
            record("2026-11-24T00:03:00Z", "calendar_read", detail: "14 events, for the dashboard"),
        ], calendar: Self.calendar)
        let now = ISO8601DateFormatter().date(from: "2026-11-24T12:00:00Z")!
        let days = ActivityLog.days(rows, calendar: Self.calendar, now: now)
        #expect(days.map(\.title) == ["Today", "Yesterday", "Friday 20 November"])
        // Three identical reads today become one line; yesterday's stays its own.
        #expect(days[0].rows.map(\.count) == [3])
        #expect(days[0].rows[0].title == "Read your calendar for the dashboard" && days[0].rows[0].detail == "14 events")
        #expect(days[1].rows.map(\.count) == [1])
        #expect(Set(rows.map(\.id)).count == rows.count)
    }
}
