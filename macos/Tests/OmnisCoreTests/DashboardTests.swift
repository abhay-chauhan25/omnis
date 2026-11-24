import Foundation
import Testing
@testable import OmnisCore

@Suite struct DashboardTests {
    let now = Zone.date("2026-11-23T20:00:00Z")      // 15:00 in New York

    func record(_ time: String, _ action: String, outcome: String = "ok", kind: String? = nil, target: String? = nil,
                detail: String? = nil) -> AuditLog.Record {
        AuditLog.Record(time: time, action: action, kind: kind, target: target, outcome: outcome, detail: detail)
    }

    @Test func activityIsReadFromTheLogInPlainWordsNewestFirst() {
        let records = [
            record("2026-11-23T18:00:00Z", "launch", kind: "launcher", target: "Ghidra"),
            record("2026-11-23T18:05:00Z", "web_search", detail: "6 results"),
            record("2026-11-23T18:06:00Z", "ask", detail: "model claude-haiku-5-5, route claude, in 900 tokens, out 100 tokens"),
            record("2026-11-23T18:07:00Z", "ask", outcome: "error", detail: "something failed"),
            record("2026-11-23T18:08:00Z", "calendar_propose", detail: "update_event"),
            record("2026-11-23T18:09:00Z", "calendar_change", detail: "delete_event"),
            record("2026-11-23T18:10:00Z", "calendar_change", outcome: "declined"),
            record("2026-11-23T18:11:00Z", "ask", detail: "model gemma4:12b, route local"),
            record("2026-11-23T18:12:00Z", "calendar_read", detail: "10 events, for the dashboard"),     // not something the user did
        ]
        #expect(DashboardData.activity(from: records).map(\.text) == [
            "Answered a question on this Mac", "Deleted an event, after you confirmed", "Answered a question with Claude",
            "Searched the web, 6 results", "Opened Ghidra",
        ])
        #expect(DashboardData.activity(from: records, limit: 2).count == 2)
        #expect(DashboardData.activity(from: []).isEmpty)
    }

    @Test func launchTilesFollowWhatIsOpenedMost() {
        func entry(_ kind: EntryKind, _ name: String) -> RegistryEntry {
            RegistryEntry(kind: kind, name: name, url: URL(fileURLWithPath: "/x/\(name)"))
        }
        let entries = [entry(.app, "Safari"), entry(.app, "Calendar"), entry(.project, "VoyagerAI"), entry(.project, "omnis"),
                       entry(.launcher, "Ghidra")]
        let records = [
            record("2026-11-22T10:00:00Z", "launch", kind: "app", target: "Safari"),
            record("2026-11-22T11:00:00Z", "launch", kind: "launcher", target: "Ghidra"),
            record("2026-11-23T11:00:00Z", "launch", kind: "launcher", target: "Ghidra"),
            record("2026-11-23T12:00:00Z", "launch", kind: "project", target: "VoyagerAI"),
            record("2026-11-23T12:30:00Z", "launch", outcome: "error", kind: "app", target: "Calendar"),
            record("2026-09-01T12:00:00Z", "launch", kind: "app", target: "Calendar"),          // too long ago
            record("2026-11-23T12:40:00Z", "launch", kind: "app", target: "Removed App"),       // no longer in the registry
        ]
        let tiles = DashboardData.tiles(from: records, entries: entries, now: now)
        // Most opened, then most recent, then the user's own projects and launchers.
        #expect(tiles.map(\.name) == ["Ghidra", "VoyagerAI", "Safari", "omnis"])
        #expect(DashboardData.tiles(from: [], entries: entries, now: now).map(\.name) == ["VoyagerAI", "omnis", "Ghidra"])
        #expect(DashboardData.tiles(from: records, entries: entries, limit: 2, now: now).count == 2)
    }

    @Test func thirtyDaysOfQuestionsBecomeAHeatmapAndTotals() {
        var records = [
            record("2026-11-23T19:10:00Z", "ask", detail: "model claude-haiku-5-5, route claude, in 9140 tokens, out 382 tokens, total 5252 ms"),
            record("2026-11-23T19:40:00Z", "ask", detail: "model x, in 1000 tokens, out 10 tokens"),
            record("2026-11-23T15:00:00Z", "ask", detail: "no numbers"),
            record("2026-11-20T19:00:00Z", "ask", detail: "in 500 tokens, out 5 tokens"),
            record("2026-11-20T19:00:00Z", "ask", outcome: "error"),
            record("2026-10-01T19:00:00Z", "ask", detail: "in 99999 tokens"),          // more than thirty days ago
            record("2026-11-23T19:00:00Z", "launch", target: "x"),
        ]
        let history = DashboardData.history(from: records, now: now, calendar: Zone.newYork)
        #expect(history.perDay.count == 30)
        #expect(history.perDay.last == 3 && history.perDay[26] == 1 && history.questions == 4)
        #expect(history.tokens == 9140 + 382 + 1000 + 10 + 500 + 5)
        #expect(history.tokensToday == 9140 + 382 + 1000 + 10)
        #expect(history.busiestHour == 14)          // 19:xx UTC is 14:xx in New York
        #expect(history.levels.last == 4 && history.levels[26] == 2 && history.levels[0] == 0)

        records = []
        let empty = DashboardData.history(from: records, now: now, calendar: Zone.newYork)
        #expect(empty.questions == 0 && empty.busiestHour == nil && empty.levels.allSatisfy { $0 == 0 })
        #expect(DashboardData.compact(1_940_000) == "1.9M" && DashboardData.compact(41_200) == "41k" && DashboardData.compact(820) == "820")
    }

    @Test func todayShowsWhatIsLeftWithTheNextEventMarked() {
        func event(_ title: String, _ start: String, _ end: String, allDay: Bool = false) -> CalendarEvent {
            CalendarEvent(title: title, start: Zone.date(start), end: Zone.date(end), allDay: allDay, calendar: "Work", key: title)
        }
        let events = [
            event("Standup", "2026-11-23T14:00:00Z", "2026-11-23T14:30:00Z"),            // already over
            event("Workshop", "2026-11-23T19:00:00Z", "2026-11-23T21:00:00Z"),           // happening now
            event("Gym", "2026-11-23T22:30:00Z", "2026-11-23T23:30:00Z"),
            event("Project review", "2026-11-23T20:28:00Z", "2026-11-23T21:00:00Z"),
            event("Mum's birthday", "2026-11-23T05:00:00Z", "2026-11-24T05:00:00Z", allDay: true),
            event("Dentist", "2026-11-24T15:00:00Z", "2026-11-24T16:00:00Z"),            // tomorrow
        ]
        let rows = DashboardData.agenda(from: events, now: now, calendar: Zone.newYork)
        #expect(rows.map(\.title) == ["Mum's birthday", "Workshop", "Project review", "Gym"])
        #expect(rows.map(\.time) == ["all day", "14:00", "15:28", "17:30"])
        #expect(rows.map(\.isNext) == [false, false, true, false])
        #expect(DashboardData.untilNext(rows, now: now) == "in 28 min")
        #expect(DashboardData.untilNext(DashboardData.agenda(from: [events[2]], now: now, calendar: Zone.newYork), now: now) == "in 2 h 30 min")
        #expect(DashboardData.untilNext([], now: now) == nil)
        #expect(DashboardData.greeting(now: now, calendar: Zone.newYork) == "Good afternoon.")
        #expect(DashboardData.greeting(now: Zone.date("2026-11-23T12:00:00Z"), calendar: Zone.newYork) == "Good morning.")
        #expect(DashboardData.greeting(now: Zone.date("2026-11-24T02:00:00Z"), calendar: Zone.newYork) == "Good evening.")
    }

    @Test func runningClaudeCodeSessionsAreFoundByFolder() {
        let listing = """
          62339 02-02:09:36 /Applications/Claude.app/Contents/MacOS/Claude
          79174       06:52 /Users/me/.local/bin/claude
          60261 06-21:31:24 claude
          43260    03:10:00 claude
            501       00:10 /usr/bin/python3
          70000       01:00 claude
        """
        let run: SessionScanner.Runner = { program, arguments in
            if program == "/bin/ps" { return listing }
            switch arguments[4] {
            case "79174": return "p79174\nfcwd\nn/Users/me/Library/Application Support/OMNIS/claude-session\n"
            case "60261": return "p60261\nfcwd\nn/Users/me/projects/omnis\n"
            case "43260": return "p43260\nfcwd\nn/Users/me/projects/VoyagerAI\n"
            case "70000": return "p70000\nfcwd\nn/Users/me\n"
            default: return ""
            }
        }
        let sessions = SessionScanner.scan(
            excluding: [URL(fileURLWithPath: "/Users/me/Library/Application Support/OMNIS/claude-session")],
            home: URL(fileURLWithPath: "/Users/me"), run: run)
        // The desktop app, OMNIS's own session and a session in the home folder are left out.
        #expect(sessions.map(\.project) == ["omnis", "VoyagerAI"])
        #expect(sessions.map(\.age) == ["6 days", "3 h"])
        #expect(SessionScanner.Session(pid: 1, elapsed: "41:07", folder: "/x").age == "41 min")
        #expect(SessionScanner.Session(pid: 1, elapsed: "00:20", folder: "/x").age == "1 min")
        #expect(SessionScanner.scan(run: { _, _ in "" }).isEmpty)
    }

    @Test func notesAreAppendedToOnePlainFileAndCountedByDay() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-notes-\(UUID().uuidString).md")
        defer { try? FileManager.default.removeItem(at: url) }
        let notes = NotesStore(url: url)
        #expect(notes.countToday(now: now, calendar: Zone.newYork) == 0)
        #expect(notes.add("  Ask Priya about\nThursday  ", now: now, calendar: Zone.newYork))
        #expect(notes.add("Second thought", now: now.addingTimeInterval(60), calendar: Zone.newYork))
        #expect(!notes.add("   \n ", now: now, calendar: Zone.newYork))
        #expect(notes.add("Yesterday's", now: now.addingTimeInterval(-86_400), calendar: Zone.newYork))
        #expect(try String(contentsOf: url, encoding: .utf8) == """
        # OMNIS notes

        - 2026-11-23 15:00  Ask Priya about Thursday
        - 2026-11-23 15:01  Second thought
        - 2026-11-22 15:00  Yesterday's

        """)
        #expect(notes.countToday(now: now, calendar: Zone.newYork) == 2)
        let mode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }

    @Test func theFocusTimerCountsDownAndFinishes() {
        var timer = FocusTimer()
        #expect(!timer.isRunning && timer.label(now: now) == "25:00" && !timer.isFinished(now: now))
        timer.start(now: now)
        #expect(timer.isRunning && timer.label(now: now.addingTimeInterval(61)) == "23:59")
        #expect(!timer.isFinished(now: now.addingTimeInterval(1499)) && timer.isFinished(now: now.addingTimeInterval(1500)))
        #expect(timer.label(now: now.addingTimeInterval(5000)) == "00:00")
        timer.stop()
        #expect(!timer.isRunning && timer.label(now: now) == "25:00")
    }

    @Test func onlyTheEndOfALongLogIsRead() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-audit-\(UUID().uuidString).log")
        defer { try? FileManager.default.removeItem(at: url) }
        #expect(AuditLog.recent(at: url).isEmpty)
        let lines = (0..<500).map { #"{"action":"ask","outcome":"ok","time":"2026-11-23T10:00:00Z","detail":"n\#($0)"}"# }
        try (lines.joined(separator: "\n") + "\nnot json\n").write(to: url, atomically: true, encoding: .utf8)
        #expect(AuditLog.recent(at: url).count == 500)
        #expect(AuditLog.recent(at: url, limit: 10).map(\.detail) == (490..<500).map { "n\($0)" })
        let tail = AuditLog.recent(at: url, maxBytes: 2000)
        #expect(tail.count > 5 && tail.count < 40 && tail.last?.detail == "n499")
    }
}
