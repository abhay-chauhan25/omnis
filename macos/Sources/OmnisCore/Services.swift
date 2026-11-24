import EventKit
import Foundation

// MARK: - Reminders

public struct ReminderItem: Equatable, Sendable {
    public let key: String
    public let title: String
    public let due: Date?
    public let dueHasTime: Bool
    public let list: String

    public init(key: String, title: String, due: Date? = nil, dueHasTime: Bool = false, list: String = "") {
        self.key = key
        self.title = title
        self.due = due
        self.dueHasTime = dueHasTime
        self.list = list
    }
}

/// The user's reminders. Replaced by a stand-in in tests.
public protocol ReminderStoring: Sendable {
    /// Reminders not yet ticked off.
    func open() async throws -> [ReminderItem]
    func lists() async throws -> [String]
    /// Adds one and returns the name of the list it went into.
    func add(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> String
    func complete(key: String) async throws
    func delete(key: String) async throws
}

public final class RemindersTools: AssistantTools, @unchecked Sendable {
    public let service = "reminders"
    public let toolNames: Set<String> = ["reminders_list", "reminders_add", "reminders_complete", "reminders_delete"]
    private let store: any ReminderStoring
    private let refs = EventRefs(prefix: "r")
    private let lock = NSLock()
    private var known: [String: ReminderItem] = [:]

    public init(store: any ReminderStoring) {
        self.store = store
    }

    static func when(_ item: ReminderItem, calendar: Calendar = .current) -> String? {
        guard let due = item.due else { return nil }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = Locale(identifier: "en_GB")
        formatter.dateFormat = item.dueHasTime ? "EEE d MMM yyyy, HH:mm" : "EEE d MMM yyyy"
        return formatter.string(from: due)
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        switch tool {
        case "reminders_list":
            var items = try await store.open()
            if let list = arguments["list"] { items = items.filter { $0.list.caseInsensitiveCompare(list) == .orderedSame } }
            items.sort { ($0.due ?? .distantFuture, $0.title) < ($1.due ?? .distantFuture, $1.title) }
            lock.withLock { for item in items { known[item.key] = item } }
            let lines = items.prefix(60).map { item -> String in
                var line = "[\(refs.ref(for: item.key))] \(CalendarFormatter.clean(item.title))"
                if let when = Self.when(item) { line += " (due \(when))" }
                if !item.list.isEmpty { line += " in \(CalendarFormatter.clean(item.list))" }
                return line
            }
            let body = lines.isEmpty ? "There are no open reminders." : lines.joined(separator: "\n")
            return .read(content: ToolArguments.fenced("The user's open reminders. Each starts with an id like [r3]; do not show ids to the user.", body),
                         note: "Read your reminders")
        case "reminders_add":
            let title = CalendarFormatter.clean(arguments["title"] ?? "")
            guard !title.isEmpty else { throw ToolRefusal("the reminder needs a title") }
            var rows: [ChangeRow] = []
            var payload = ["action": "add", "title": title]
            if let text = arguments["due"] {
                guard let due = ToolArguments.moment(text) else { throw ToolRefusal("the due date was not valid; use YYYY-MM-DD or YYYY-MM-DDTHH:MM") }
                payload["due"] = String(due.date.timeIntervalSince1970)
                payload["dueHasTime"] = due.hasTime ? "true" : "false"
                rows.append(ChangeRow("Due", Self.when(ReminderItem(key: "", title: title, due: due.date, dueHasTime: due.hasTime)) ?? ""))
            }
            if let list = arguments["list"].map(CalendarFormatter.clean), !list.isEmpty {
                let lists = try await store.lists()
                guard let match = lists.first(where: { $0.caseInsensitiveCompare(list) == .orderedSame }) else {
                    throw ToolRefusal("there is no reminders list called \"\(list)\". The lists are: \(lists.joined(separator: ", "))")
                }
                payload["list"] = match
                rows.append(ChangeRow("List", match))
            }
            if let notes = arguments["notes"].map(CalendarFormatter.cleanNotes), !notes.isEmpty {
                payload["notes"] = notes
                rows.append(ChangeRow("Notes", notes))
            }
            return .proposal(ActionProposal(service: service, kind: "add_reminder", heading: "New reminder", title: title, rows: rows,
                                            confirmLabel: "Add Reminder", declineLabel: "Don't Add", payload: payload))
        case "reminders_complete", "reminders_delete":
            let deleting = tool == "reminders_delete"
            if deleting, !access.deletes {
                throw ToolRefusal("deleting was not asked for in the user's message. Ask them to say plainly what to delete")
            }
            guard let key = refs.key(for: (arguments["reminder"] ?? "").trimmingCharacters(in: CharacterSet(charactersIn: "[] "))),
                  let item = lock.withLock({ known[key] }) else {
                throw ToolRefusal("that reminder id is not known. List the reminders first and use the id shown there")
            }
            var rows: [ChangeRow] = []
            if let when = Self.when(item) { rows.append(ChangeRow("Due", when)) }
            if !item.list.isEmpty { rows.append(ChangeRow("List", item.list)) }
            return .proposal(ActionProposal(
                service: service, kind: deleting ? "delete_reminder" : "complete_reminder",
                heading: deleting ? "Delete reminder" : "Mark as done", title: CalendarFormatter.clean(item.title), rows: rows,
                warning: deleting ? "This cannot be undone." : nil,
                confirmLabel: deleting ? "Delete Reminder" : "Mark as Done", declineLabel: deleting ? "Don't Delete" : "Not Yet",
                destructive: deleting, payload: ["action": deleting ? "delete" : "complete", "key": key]))
        default:
            throw ToolRefusal("that is not something OMNIS can do with reminders")
        }
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        let payload = proposal.payload
        switch payload["action"] {
        case "add":
            let due = payload["due"].flatMap(Double.init).map { Date(timeIntervalSince1970: $0) }
            let list = try await store.add(title: payload["title"] ?? "", due: due, dueHasTime: payload["dueHasTime"] == "true",
                                           list: payload["list"], notes: payload["notes"])
            return list.isEmpty ? "Added" : "Added to \(list)"
        case "complete":
            try await store.complete(key: payload["key"] ?? "")
            return "Marked as done"
        case "delete":
            try await store.delete(key: payload["key"] ?? "")
            return "Deleted"
        default:
            throw ToolRefusal("that could not be carried out")
        }
    }
}

/// The Mac's reminders through EventKit. macOS asks for permission on first use.
public final class EventKitReminders: ReminderStoring, @unchecked Sendable {
    private let store = EKEventStore()

    public init() {}

    private func ensureAccess() async throws {
        switch EKEventStore.authorizationStatus(for: .reminder) {
        case .fullAccess:
            return
        case .notDetermined:
            guard (try? await store.requestFullAccessToReminders()) == true else {
                throw ToolRefusal("OMNIS has not been allowed to use your reminders. You can allow it in System Settings, under Privacy & Security, Reminders")
            }
        default:
            throw ToolRefusal("OMNIS has not been allowed to use your reminders. You can allow it in System Settings, under Privacy & Security, Reminders")
        }
    }

    private func fetch(_ predicate: NSPredicate) async -> [EKReminder] {
        await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { found in
                continuation.resume(returning: found ?? [])
            }
        }
    }

    public func open() async throws -> [ReminderItem] {
        try await ensureAccess()
        let found = await fetch(store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: nil))
        return found.map { reminder in
            let parts = reminder.dueDateComponents
            return ReminderItem(key: reminder.calendarItemIdentifier, title: reminder.title ?? "",
                                due: parts.flatMap { Calendar.current.date(from: $0) }, dueHasTime: parts?.hour != nil,
                                list: reminder.calendar?.title ?? "")
        }
    }

    public func lists() async throws -> [String] {
        try await ensureAccess()
        return store.calendars(for: .reminder).filter(\.allowsContentModifications).map(\.title)
    }

    public func add(title: String, due: Date?, dueHasTime: Bool, list: String?, notes: String?) async throws -> String {
        try await ensureAccess()
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.notes = notes
        let target = list.flatMap { name in store.calendars(for: .reminder).first { $0.title == name && $0.allowsContentModifications } }
            ?? store.defaultCalendarForNewReminders()
        guard let target else { throw ToolRefusal("there is no reminders list to add to") }
        reminder.calendar = target
        if let due {
            let units: Set<Calendar.Component> = dueHasTime ? [.year, .month, .day, .hour, .minute] : [.year, .month, .day]
            reminder.dueDateComponents = Calendar.current.dateComponents(units, from: due)
            if dueHasTime { reminder.addAlarm(EKAlarm(absoluteDate: due)) }
        }
        try store.save(reminder, commit: true)
        return target.title
    }

    private func find(_ key: String) throws -> EKReminder {
        guard let reminder = store.calendarItem(withIdentifier: key) as? EKReminder else {
            throw ToolRefusal("that reminder no longer exists")
        }
        return reminder
    }

    public func complete(key: String) async throws {
        try await ensureAccess()
        let reminder = try find(key)
        reminder.isCompleted = true
        try store.save(reminder, commit: true)
    }

    public func delete(key: String) async throws {
        try await ensureAccess()
        try store.remove(try find(key), commit: true)
    }
}

// MARK: - GitHub

/// What is waiting for the user on GitHub. Reading only, through the `gh`
/// tool the user is already signed in to.
public final class GitHubTools: AssistantTools, Sendable {
    public let service = "github"
    public let toolNames: Set<String> = ["github_overview"]
    private let gh: URL
    private let runner: CommandRunner

    public init(gh: URL, run: @escaping CommandRunner = Commands.system) {
        self.gh = gh
        self.runner = run
    }

    static func lines(from output: String) -> [String] {
        guard let items = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [[String: Any]] else { return [] }
        return items.prefix(15).compactMap { item in
            guard let title = item["title"] as? String, let number = (item["number"] as? NSNumber)?.intValue else { return nil }
            let repository = (item["repository"] as? [String: Any])?["nameWithOwner"] as? String ?? ""
            return "\(repository)#\(number): \(CalendarFormatter.clean(title))"
        }
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        guard tool == "github_overview" else { throw ToolRefusal("that is not something OMNIS can do with GitHub") }
        let fields = ["--json", "title,number,repository", "--limit", "15", "--state", "open"]
        async let review = runner(gh, ["search", "prs", "--review-requested", "@me"] + fields, nil)
        async let mine = runner(gh, ["search", "prs", "--author", "@me"] + fields, nil)
        async let issues = runner(gh, ["search", "issues", "--assignee", "@me"] + fields, nil)
        let results = await [review, mine, issues]
        guard results.contains(where: { $0.status == 0 }) else {
            throw ToolRefusal("GitHub could not be read: \(String(results[0].output.suffix(200)).trimmingCharacters(in: .whitespacesAndNewlines))")
        }
        let titles = ["Pull requests waiting for your review", "Your open pull requests", "Open issues assigned to you"]
        var sections: [String] = []
        for (index, result) in results.enumerated() {
            let found = result.status == 0 ? Self.lines(from: result.output) : []
            sections.append("\(titles[index]):\n" + (found.isEmpty ? "(none)" : found.map { "- \($0)" }.joined(separator: "\n")))
        }
        return .read(content: ToolArguments.fenced("From the user's GitHub.", sections.joined(separator: "\n\n")), note: "Checked GitHub")
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        throw ToolRefusal("OMNIS only reads GitHub")
    }
}

// MARK: - Spotify

/// Playback in the Spotify app on this Mac. These are harmless and easily
/// undone, so they are carried out at once with no preview.
public final class SpotifyTools: AssistantTools, Sendable {
    public let service = "spotify"
    public let toolNames: Set<String> = ["spotify_now_playing", "spotify_control", "spotify_search"]
    private let runner: CommandRunner
    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let opener = URL(fileURLWithPath: "/usr/bin/open")

    public init(run: @escaping CommandRunner = Commands.system) {
        self.runner = run
    }

    /// Every script is fixed text. Nothing from a model is ever put into one.
    static let scripts: [String: String] = [
        "play": "tell application \"Spotify\" to play",
        "pause": "tell application \"Spotify\" to pause",
        "toggle": "tell application \"Spotify\" to playpause",
        "next": "tell application \"Spotify\" to next track",
        "previous": "tell application \"Spotify\" to previous track",
    ]
    static let nowPlaying = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "nothing"
            return (player state as string) & "|" & (name of current track) & "|" & (artist of current track) & "|" & (album of current track)
        end tell
    else
        return "closed"
    end if
    """

    private func script(_ text: String) async throws -> String {
        let result = await runner(Self.osascript, ["-e", text], nil)
        guard result.status == 0 else {
            let why = result.output.contains("-1743") ? "OMNIS has not been allowed to control Spotify. You can allow it in System Settings, under Privacy & Security, Automation"
                : "Spotify did not respond"
            throw ToolRefusal(why)
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func describe() async throws -> String {
        let state = try await script(Self.nowPlaying)
        if state == "closed" { return "Spotify is not open." }
        if state == "nothing" { return "Nothing is playing in Spotify." }
        let parts = state.components(separatedBy: "|")
        guard parts.count >= 3 else { return "Spotify is open." }
        let track = "\(CalendarFormatter.clean(parts[1])) by \(CalendarFormatter.clean(parts[2]))"
        return parts[0] == "playing" ? "Playing: \(track)." : "Paused on: \(track)."
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        switch tool {
        case "spotify_now_playing":
            return .read(content: try await describe(), note: "Checked Spotify")
        case "spotify_control":
            let action = (arguments["action"] ?? "").lowercased()
            guard let text = Self.scripts[action] else { throw ToolRefusal("the action must be play, pause, toggle, next or previous") }
            _ = try await script(text)
            // Give the app a moment to move on before saying what is playing.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let now = (try? await describe()) ?? ""
            return .done(content: "Done. \(now)", note: "Controlled Spotify")
        case "spotify_search":
            let query = CalendarFormatter.clean(arguments["query"] ?? "")
            guard !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: .alphanumerics) else {
                throw ToolRefusal("say what to search for")
            }
            // Handed to `open` as one argument. Only a spotify: address is ever built.
            let result = await runner(Self.opener, ["spotify:search:\(encoded)"], nil)
            guard result.status == 0 else { throw ToolRefusal("Spotify could not be opened") }
            return .done(content: "Spotify is showing search results for \"\(query)\". OMNIS cannot pick and play a result yet, so tell the user to choose one.",
                         note: "Searched Spotify")
        default:
            throw ToolRefusal("that is not something OMNIS can do with Spotify")
        }
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        throw ToolRefusal("nothing to confirm for Spotify")
    }
}
