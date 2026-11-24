import Foundation
import Testing
@testable import OmnisCore

@Suite struct ClaudeStatsTests {
    let now = Zone.date("2026-11-23T20:00:00Z")      // Monday 23 November, 15:00 in New York

    let sample = """
    {"version":5,"lastComputedDate":"2026-11-23",
     "dailyActivity":[
       {"date":"2026-09-23","messageCount":150,"sessionCount":3,"toolCallCount":11},
       {"date":"2026-11-18","messageCount":40,"sessionCount":1,"toolCallCount":5},
       {"date":"2026-11-19","messageCount":400,"sessionCount":2,"toolCallCount":90},
       {"date":"2026-11-20","messageCount":10,"sessionCount":0,"toolCallCount":1},
       {"date":"2026-11-22","messageCount":100,"sessionCount":1,"toolCallCount":20},
       {"date":"2026-11-23","messageCount":229,"sessionCount":0,"toolCallCount":105},
       {"date":"not a date","messageCount":9999}],
     "dailyModelTokens":[
       {"date":"2026-09-23","tokensByModel":{"claude-opus-5-5":1000000,"claude-opus-4-8":250000}},
       {"date":"2026-11-19","tokensByModel":{"claude-fable-5-2":3000000,"claude-haiku-5-5":500000}},
       {"date":"2026-11-23","tokensByModel":{"claude-fable-5-2":1000000,"claude-sonnet-5-5":500000,"claude-haiku-5-5":-5}}],
     "modelUsage":{
       "claude-opus-5-5":{"inputTokens":14000,"outputTokens":10000000,"cacheReadInputTokens":1800000000,"cacheCreationInputTokens":46000000},
       "claude-fable-5-2":{"inputTokens":2500,"outputTokens":3000000,"cacheReadInputTokens":470000000,"cacheCreationInputTokens":18000000}},
     "totalSessions":25,"totalMessages":20623,
     "longestSession":{"sessionId":"x","duration":348665286,"messageCount":2204},
     "hourCounts":{"1":1,"12":3,"14":9,"99":50,"x":4}}
    """

    func stats() throws -> ClaudeStats {
        try #require(ClaudeStats.parse(Data(sample.utf8), calendar: Zone.newYork))
    }

    @Test func theSummaryFileIsReadDefensively() throws {
        let stats = try stats()
        #expect(stats.days.count == 6)                               // the entry with a bad date is dropped
        #expect(stats.days.first?.tokens == ["claude-opus-5-5": 1_000_000, "claude-opus-4-8": 250_000])
        #expect(stats.days.last?.tokens["claude-haiku-5-5"] == 0)    // a negative count is not believed
        #expect(stats.totalSessions == 25 && stats.longestSessionSeconds == 348_665)
        #expect(stats.hourCounts == [1: 1, 12: 3, 14: 9])
        #expect(stats.computed == Zone.date("2026-11-23T05:00:00Z"))
        for bad in ["", "[]", "{}", "{\"dailyActivity\": \"no\"}", "not json"] {
            #expect(ClaudeStats.parse(Data(bad.utf8)) == nil, "\(bad)")
        }
        #expect(ClaudeStats.load(from: URL(fileURLWithPath: "/nonexistent/stats.json")) == nil)
    }

    @Test func theLastSevenDays() throws {
        let week = try stats().summary(.week, now: now, calendar: Zone.newYork)
        #expect(week.cells.map(\.messages) == [0, 40, 400, 10, 0, 100, 229])     // Tue 17 to Mon 23
        #expect(week.cells.map(\.level) == [0, 1, 4, 1, 0, 1, 2])
        #expect(week.totalDays == 7 && week.activeDays == 5)
        #expect(week.messages == 779 && week.toolCalls == 221 && week.sessions == 4)
        #expect(week.tokens == 5_000_000)
        #expect(week.favourite == "Fable 5.2")
        #expect(week.models == [.init(name: "Fable 5.2", percent: 80), .init(name: "Haiku 5.5", percent: 10),
                                .init(name: "Sonnet 5.5", percent: 10)])
        #expect(week.mostActive?.messages == 400)
        #expect(week.longestStreak == 3 && week.currentStreak == 2)
        #expect(week.longestSession == nil && week.breakdown == nil && week.busiestHour == nil)
    }

    @Test func allTimeAddsTheTotalsOnlyKnownOverall() throws {
        let all = try stats().summary(.all, now: now, calendar: Zone.newYork)
        #expect(all.cells.first?.date == Zone.date("2026-09-23T04:00:00Z"))       // from the first day on record
        #expect(all.totalDays == 62 && all.activeDays == 6)
        #expect(all.sessions == 25)
        #expect(all.tokens == 6_250_000 && all.favourite == "Fable 5.2")
        #expect(all.longestSession == "4d 0h 51m")
        #expect(all.busiestHour == 14)
        #expect(all.breakdown == .init(input: 16_500, output: 13_000_000, cacheRead: 2_270_000_000, cacheWrite: 64_000_000))
        #expect(all.novelsWritten == 108)
        #expect(DashboardData.compactLarge(all.breakdown?.all ?? 0) == "2.3b")
        #expect(all.longestStreak == 3 && all.currentStreak == 2)

        let month = try stats().summary(.month, now: now, calendar: Zone.newYork)
        #expect(month.totalDays == 30 && month.activeDays == 5 && month.tokens == 5_000_000)

        // A streak is not broken by a today that has no activity yet.
        let tomorrow = try stats().summary(.week, now: now.addingTimeInterval(86_400), calendar: Zone.newYork)
        #expect(tomorrow.currentStreak == 2)
        let later = try stats().summary(.week, now: now.addingTimeInterval(3 * 86_400), calendar: Zone.newYork)
        #expect(later.currentStreak == 0)
    }

    @Test func daysAreLaidOutInWeekColumnsFromMonday() throws {
        let week = try stats().summary(.week, now: now, calendar: Zone.newYork)
        let columns = ClaudeStats.weeks(week.cells, calendar: Zone.newYork)
        // Tuesday 17 to Sunday 22 fill one column from its second row; Monday 23 starts the next.
        #expect(columns.count == 2)
        #expect(columns[0].map { $0?.messages } == [nil, 0, 40, 400, 10, 0, 100])
        #expect(columns[1].map { $0?.messages } == [229, nil, nil, nil, nil, nil, nil])

        let all = try stats().summary(.all, now: now, calendar: Zone.newYork)
        let grid = ClaudeStats.weeks(all.cells, calendar: Zone.newYork)
        #expect(grid.count == 10 && grid.allSatisfy { $0.count == 7 })
        #expect(grid.flatMap { $0 }.compactMap { $0 }.count == 62)
        #expect(ClaudeStats.monthLabels(grid, calendar: Zone.newYork) == ["Sep", "", "Oct", "", "", "", "Nov", "", "", ""])
    }

    @Test func namesAndLengthsReadNaturally() {
        #expect(ClaudeStats.modelName("claude-opus-5-5") == "Opus 5.5")
        #expect(ClaudeStats.modelName("claude-haiku-5-5-20261001") == "Haiku 5.5")
        #expect(ClaudeStats.modelName("gemma4:12b") == "Gemma4:12b")
        #expect(ClaudeStats.duration(348_665) == "4d 0h 51m" && ClaudeStats.duration(3700) == "1h 1m" && ClaudeStats.duration(20) == "1m")
        #expect(StatsRange.allCases.map(\.title) == ["All time", "Last 7 days", "Last 30 days"])
    }
}
