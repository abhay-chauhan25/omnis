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
    /// The reminder's title as it is now, or nil if it no longer exists.
    func title(of key: String) async throws -> String?
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
                // A reminder with a time also alerts you then. The card says so.
                if due.hasTime { rows.append(ChangeRow("Alert", "at that time")) }
            }
            if arguments["list"] == nil { rows.append(ChangeRow("List", "your default list")) }
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
                destructive: deleting,
                payload: ["action": deleting ? "delete" : "complete", "key": key, "title": CalendarFormatter.clean(item.title)]))
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
        case "complete", "delete":
            // If it has changed since it was listed, the card no longer says what would happen.
            let key = payload["key"] ?? ""
            guard let current = try await store.title(of: key) else { throw ToolRefusal("that reminder no longer exists") }
            guard CalendarFormatter.clean(current) == payload["title"] else {
                throw ToolRefusal("that reminder has changed since it was listed. Ask for your reminders again")
            }
            if payload["action"] == "delete" {
                try await store.delete(key: key)
                return "Deleted"
            }
            try await store.complete(key: key)
            return "Marked as done"
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

    public func title(of key: String) async throws -> String? {
        try await ensureAccess()
        return (store.calendarItem(withIdentifier: key) as? EKReminder)?.title
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

    /// The entries in one search result, or nil if the output could not be
    /// read: that must never be mistaken for "nothing there".
    static func lines(from output: String) -> [String]? {
        // Anything `gh` printed before the list, such as a notice, is skipped.
        guard let start = output.firstIndex(of: "["),
              let items = try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [[String: Any]] else { return nil }
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
            guard result.status == 0, let found = Self.lines(from: result.output) else {
                sections.append("\(titles[index]):\n(this list could not be read; say so, do not say it is empty)")
                continue
            }
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
///
/// Playing something by name has two halves. Finding it is a search of
/// Spotify's catalogue through its web service, which the user connects once
/// and which may only read. Playing it is done by the Spotify app here.
public final class SpotifyTools: AssistantTools, Sendable {
    public let service = "spotify"
    public let toolNames: Set<String> = ["spotify_now_playing", "spotify_control", "spotify_search", "spotify_play", "spotify_queue"]
    /// What is playing is not personal information.
    public let holdsPersonalData = false
    public let outwardTools: Set<String> = ["spotify_search", "spotify_play", "spotify_queue"]
    private let runner: CommandRunner
    private let catalogue: (any SpotifyCatalogue)?
    /// The matches from the last search, so "the second one" can be played without searching again.
    private let lastMatches = Matches()

    private final class Matches: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [SpotifyItem] = []
        func set(_ fresh: [SpotifyItem]) { lock.withLock { items = fresh } }
        func item(_ id: String) -> SpotifyItem? {
            guard id.hasPrefix("s"), let number = Int(id.dropFirst()), number >= 1 else { return nil }
            return lock.withLock { number <= items.count ? items[number - 1] : nil }
        }
    }
    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    private static let opener = URL(fileURLWithPath: "/usr/bin/open")

    public init(catalogue: (any SpotifyCatalogue)? = nil, run: @escaping CommandRunner = Commands.system) {
        self.catalogue = catalogue
        self.runner = run
    }

    /// Fixed text. What to play is handed over beside it, never written into it.
    static let playScript = """
    on run arguments
        tell application "Spotify" to play track (item 1 of arguments)
    end run
    """

    static let connectHelp = "Picking a song by name needs Spotify's catalogue, which is not connected. Tell the user: to connect it, type /spotify in "
        + "OMNIS for the steps. Until then spotify_search can show search results in the Spotify app for them to choose from."

    /// A playlist of the user's own with this name, if there is one.
    static func ownPlaylist(named query: String, in playlists: [SpotifyItem]) -> SpotifyItem? {
        let wanted = TextNormalizer.normalize(query).replacingOccurrences(of: " playlist", with: "")
        guard !wanted.isEmpty else { return nil }
        let named = playlists.map { ($0, TextNormalizer.normalize($0.name)) }
        return named.first { $0.1 == wanted }?.0 ?? named.first { $0.1.hasPrefix(wanted) }?.0 ?? named.first { $0.1.contains(wanted) }?.0
    }

    private func play(_ item: SpotifyItem) async throws {
        // Only an address Spotify itself would issue is ever handed to the app.
        guard let uri = item.uri else { throw ToolRefusal("Spotify gave something that cannot be played") }
        try await play(address: uri)
    }

    private func play(address uri: String) async throws {
        let result = await runner(Self.osascript, ["-e", Self.playScript, uri], nil)
        guard result.status == 0 else {
            throw ToolRefusal(result.output.contains("-1743") ? "OMNIS has not been allowed to control Spotify. You can allow it in System Settings, under Privacy & Security, Automation"
                              : "the Spotify app did not start playing it")
        }
    }

    private func find(_ arguments: [String: String]) async throws -> (SpotifyItem, [SpotifyItem]) {
        if let pick = arguments["pick"], !pick.isEmpty {
            guard let chosen = lastMatches.item(pick.lowercased()) else { throw ToolRefusal("there is no match \(pick.prefix(8)); search again") }
            return (chosen, [])
        }
        guard let catalogue, catalogue.isConnected else { throw ToolRefusal(Self.connectHelp) }
        let query = CalendarFormatter.clean(arguments["query"] ?? "")
        guard !query.isEmpty, query.count <= 200 else { throw ToolRefusal("say what to play") }
        let kind = SpotifyItem.Kind(rawValue: (arguments["kind"] ?? "track").lowercased()) ?? .track
        // A playlist is looked for among the user's own first: "my gym playlist" means theirs.
        if kind == .playlist, let own = Self.ownPlaylist(named: query, in: (try? await catalogue.playlists()) ?? []) {
            return (own, [])
        }
        let found = try await catalogue.search(query, kind: kind)
        guard let first = found.first else { throw ToolRefusal("Spotify found nothing for \"\(query)\"") }
        return (first, Array(found.dropFirst()))
    }

    /// Every script is fixed text. Nothing from a model is ever put into one.
    static let scripts: [String: String] = [
        "play": "tell application \"Spotify\" to play",
        "pause": "tell application \"Spotify\" to pause",
        "toggle": "tell application \"Spotify\" to playpause",
        "next": "tell application \"Spotify\" to next track",
        "previous": "tell application \"Spotify\" to previous track",
        "shuffle_on": "tell application \"Spotify\" to set shuffling to true",
        "shuffle_off": "tell application \"Spotify\" to set shuffling to false",
        "repeat_on": "tell application \"Spotify\" to set repeating to true",
        "repeat_off": "tell application \"Spotify\" to set repeating to false",
        "volume_up": """
        tell application "Spotify"
            if sound volume < 85 then
                set sound volume to (sound volume + 15)
            else
                set sound volume to 100
            end if
        end tell
        """,
        "volume_down": """
        tell application "Spotify"
            if sound volume > 15 then
                set sound volume to (sound volume - 15)
            else
                set sound volume to 0
            end if
        end tell
        """,
    ]
    /// Fixed text. The level is handed over beside it as a whole number from 0 to 100.
    static let volumeScript = """
    on run arguments
        tell application "Spotify" to set sound volume to ((item 1 of arguments) as integer)
    end run
    """
    static let settings = """
    tell application "Spotify" to return (sound volume as string) & " " & (shuffling as string) & " " & (repeating as string)
    """

    /// The volume, shuffle and repeat as they now are, in words.
    private func settingsLine() async -> String {
        guard let parts = (try? await script(Self.settings))?.split(separator: " "), parts.count == 3 else { return "" }
        return "Volume \(parts[0]) out of 100, shuffle \(parts[1] == "true" ? "on" : "off"), repeat \(parts[2] == "true" ? "on" : "off")."
    }
    static let nowPlaying = """
    if application "Spotify" is running then
        tell application "Spotify"
            if player state is stopped then return "nothing"
            set gap to (ASCII character 31)
            set art to ""
            try
                set art to (artwork url of current track)
            end try
            return (player state as string) & gap & (name of current track) & gap & (artist of current track) & gap & art
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

    /// What is playing, piece by piece, for showing rather than for telling a model.
    public struct Track: Equatable, Sendable {
        public let title: String
        public let artist: String
        public let playing: Bool
        /// Where the cover picture is, if Spotify gave an ordinary web address for it.
        public let artwork: URL?

        public init(title: String, artist: String, playing: Bool, artwork: URL?) {
            self.title = title; self.artist = artist; self.playing = playing; self.artwork = artwork
        }
    }

    /// The track in Spotify now, or nil if it is closed or nothing is loaded.
    public func track() async throws -> Track? {
        let parts = try await script(Self.nowPlaying).components(separatedBy: "\u{1F}")
        guard parts.count >= 3 else { return nil }
        let art = parts.count > 3 ? URL(string: parts[3]) : nil
        return Track(title: CalendarFormatter.clean(parts[1]), artist: CalendarFormatter.clean(parts[2]), playing: parts[0] == "playing",
                     artwork: art?.scheme == "https" ? art : nil)
    }

    func describe() async throws -> String {
        let state = try await script(Self.nowPlaying)
        if state == "closed" { return "Spotify is not open." }
        if state == "nothing" { return "Nothing is playing in Spotify." }
        // The parts are separated by a character that cannot appear in a title.
        let parts = state.components(separatedBy: "\u{1F}")
        guard parts.count >= 3 else { return "Spotify is open." }
        let track = "\(CalendarFormatter.clean(parts[1])) by \(CalendarFormatter.clean(parts[2]))"
        return parts[0] == "playing" ? "Playing: \(track)." : "Paused on: \(track)."
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        switch tool {
        case "spotify_now_playing":
            return .read(content: try await describe(), note: "Checked Spotify")
        case "spotify_control":
            let action = (arguments["action"] ?? "").lowercased().replacingOccurrences(of: " ", with: "_")
            if action == "volume" {
                // A whole number from 0 to 100 and nothing else.
                guard let level = Int(arguments["level"] ?? ""), (0...100).contains(level) else { throw ToolRefusal("the volume level must be a number from 0 to 100") }
                let result = await runner(Self.osascript, ["-e", Self.volumeScript, String(level)], nil)
                guard result.status == 0 else { throw ToolRefusal("Spotify did not respond") }
                return .done(content: "Done. \(await settingsLine())", note: "Controlled Spotify")
            }
            guard let text = Self.scripts[action] else {
                throw ToolRefusal("the action must be play, pause, toggle, next, previous, shuffle_on, shuffle_off, repeat_on, repeat_off, volume_up, volume_down or volume")
            }
            _ = try await script(text)
            if action.hasPrefix("shuffle") || action.hasPrefix("repeat") || action.hasPrefix("volume") {
                return .done(content: "Done. \(await settingsLine())", note: "Controlled Spotify")
            }
            // Give the app a moment to move on before saying what is playing.
            try? await Task.sleep(nanoseconds: 400_000_000)
            let now = (try? await describe()) ?? ""
            return .done(content: "Done. \(now)", note: "Controlled Spotify")
        case "spotify_queue":
            let (item, others) = try await find(arguments)
            guard item.kind == .track else { throw ToolRefusal("only a song can be added to what plays next") }
            guard let catalogue else { throw ToolRefusal(Self.connectHelp) }
            try await catalogue.queue(item)
            if !others.isEmpty || arguments["pick"] == nil { lastMatches.set([item] + others) }
            return .done(content: "Added \(item.spoken) to play next.", note: "Queued in Spotify")
        case "spotify_play" where (arguments["kind"] ?? "").lowercased() == "liked":
            guard let catalogue, catalogue.isConnected else { throw ToolRefusal(Self.connectHelp) }
            let liked = try await catalogue.liked()
            if let list = liked.list {
                try? await play(address: list)
                try? await Task.sleep(nanoseconds: 700_000_000)
                // The Spotify app does not say whether it took the list, so what is playing is looked at.
                if (try? await track())?.playing == true { return .done(content: "Playing the user's Liked Songs.", note: "Played from Spotify") }
            }
            guard let newest = liked.newest else { throw ToolRefusal("there are no liked songs to play") }
            try await play(newest)
            return .done(content: "The Liked Songs list would not start as a list, so the newest liked song is playing: \(newest.spoken).", note: "Played from Spotify")
        case "spotify_play":
            let (item, others) = try await find(arguments)
            try await play(item)
            if !others.isEmpty || arguments["pick"] == nil { lastMatches.set([item] + others) }
            let rest = others.enumerated().map { "s\($0.offset + 2): \($0.element.spoken)" }.joined(separator: "; ")
            return .done(content: "Now playing \(item.spoken)." + (rest.isEmpty ? "" : " If that is the wrong one, the other matches were \(rest)."),
                         note: "Played from Spotify")
        case "spotify_search":
            let query = CalendarFormatter.clean(arguments["query"] ?? "")
            let plain = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
            guard !query.isEmpty, let encoded = query.addingPercentEncoding(withAllowedCharacters: plain) else {
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
