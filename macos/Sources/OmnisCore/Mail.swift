import Foundation

/// Reading the user's email, through the Mail app on this Mac.
///
/// Reading only: nothing here sends, replies, deletes, moves or marks
/// anything. It reads the inbox of one account, the one the user chose, and
/// only when asked. Email is written by other people, so its text is handed
/// to a model as information to read, never as instructions, and a chat that
/// has been given an email is held to the same rules as one that holds a file.
public final class MailTools: AssistantTools, @unchecked Sendable {
    public let service = "mail"
    public let toolNames: Set<String> = ["mail_list", "mail_read"]
    public let deliversOthersWords = true
    private let runner: CommandRunner
    private let defaults: UserDefaults
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    /// Mail's own numbers for the messages last listed, in order, and when. "m3" is the third.
    private var listed: [Int] = []
    private var listedAt = Date.distantPast

    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    static let accountKey = "OMNISMailAccount"
    /// How long the ids from a list can be used to read one.
    static let idSeconds: TimeInterval = 600
    static let defaultDays = 90
    static let maxBodyCharacters = 6_000

    public init(run: @escaping CommandRunner = Commands.system, defaults: UserDefaults = .standard, now: @escaping @Sendable () -> Date = { Date() }) {
        self.runner = run
        self.defaults = defaults
        self.now = now
    }

    /// Forgets which account was chosen. The next request picks again.
    public static func forgetAccount(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: accountKey)
    }

    // Both scripts are fixed text. The account's name, the count and the message's number are handed over beside them.

    /// The newest messages in the account's inbox: number, sender, subject, age in seconds, read or not.
    /// With no account named, the names of the accounts that are switched on in Mail.
    static let listScript = """
    on run arguments
        set wantedAccount to item 1 of arguments
        set most to (item 2 of arguments) as integer
        set gap to (ASCII character 31)
        set rowEnd to (ASCII character 30)
        tell application "Mail"
            with timeout of 40 seconds
                set names to name of (every account whose enabled is true)
                if wantedAccount is "" then
                    set out to "accounts"
                    repeat with oneName in names
                        set out to out & gap & oneName
                    end repeat
                    return out
                end if
                if names does not contain wantedAccount then return "missing"
                try
                    set box to mailbox "Inbox" of account wantedAccount
                    set total to count of messages of box
                on error
                    return "nobox"
                end try
                if total is 0 then return "ok"
                if total < most then set most to total
                -- The newest are wanted, whichever end of the inbox Mail keeps them at.
                set firstOne to 1
                if (date received of message 1 of box) < (date received of message total of box) then set firstOne to total - most + 1
                set lastOne to firstOne + most - 1
                set ids to id of messages firstOne thru lastOne of box
                set senders to sender of messages firstOne thru lastOne of box
                set subjects to subject of messages firstOne thru lastOne of box
                set dates to date received of messages firstOne thru lastOne of box
                set reads to read status of messages firstOne thru lastOne of box
            end timeout
        end tell
        set rightNow to current date
        set out to "ok"
        repeat with i from 1 to count of ids
            set out to out & rowEnd & (item i of ids) & gap & (item i of senders) & gap & (item i of subjects) & gap & ((rightNow - (item i of dates)) as integer) & gap & (item i of reads)
        end repeat
        return out
    end run
    """

    /// One message: sender, subject, age in seconds, the names of its attachments, and its text.
    static let readScript = """
    on run arguments
        set wantedAccount to item 1 of arguments
        set wantedID to (item 2 of arguments) as integer
        set gap to (ASCII character 31)
        set rowEnd to (ASCII character 30)
        tell application "Mail"
            with timeout of 40 seconds
                try
                    set box to mailbox "Inbox" of account wantedAccount
                on error
                    return "nobox"
                end try
                set found to (messages of box whose id is wantedID)
                if (count of found) is 0 then return "gone"
                set one to item 1 of found
                set fileNames to ""
                try
                    repeat with oneFile in (mail attachments of one)
                        set fileNames to fileNames & (name of oneFile) & rowEnd
                    end repeat
                end try
                set body to (content of one) as string
                if (count of body) > 12000 then set body to text 1 thru 12000 of body
                return "ok" & gap & (sender of one) & gap & (subject of one) & gap & (((current date) - (date received of one)) as integer) & gap & fileNames & gap & body
            end timeout
        end tell
    end run
    """

    struct Row: Equatable {
        let id: Int
        let sender: String
        let subject: String
        let received: Date
        let unread: Bool
    }

    private func script(_ text: String, _ arguments: [String]) async throws -> String {
        // The "--" ends osascript's own options, so a value that begins with a dash is only ever a value.
        let result = await runner(Self.osascript, ["-e", text, "--"] + arguments, nil)
        guard result.status == 0 else {
            throw ToolRefusal(result.output.contains("-1743")
                ? "OMNIS has not been allowed to use the Mail app. You can allow it in System Settings, under Privacy & Security, Automation"
                : result.output.contains("-1712") ? "the Mail app took too long to answer" : "the Mail app did not answer")
        }
        return result.output.trimmingCharacters(in: .newlines)
    }

    /// The account whose inbox is read. It is chosen once, when exactly one
    /// account is switched on in Mail, and remembered, so that switching
    /// another account on later does not quietly widen what OMNIS reads.
    private func account() async throws -> (name: String, new: Bool) {
        if let chosen = defaults.string(forKey: Self.accountKey), !chosen.isEmpty { return (chosen, false) }
        let parts = try await script(Self.listScript, ["", "0"]).components(separatedBy: "\u{1F}")
        let names = parts.first == "accounts" ? Array(parts.dropFirst()).filter { !$0.isEmpty } : []
        guard names.count == 1, let only = names.first else {
            throw ToolRefusal(names.isEmpty ? "no email account is switched on in the Mail app"
                : "\(names.count) email accounts are switched on in the Mail app, and OMNIS reads only one. Tell the user to leave only "
                    + "the one they want switched on in Mail's settings and ask again; OMNIS will remember it")
        }
        defaults.set(only, forKey: Self.accountKey)
        return (only, true)
    }

    private func refusal(for reply: String, account: String) -> ToolRefusal? {
        switch reply {
        case "missing":
            return ToolRefusal("the email account OMNIS was set up to read is not switched on in the Mail app. "
                + "Tell the user to switch it on, or to type /mail forget in OMNIS to choose again")
        case "nobox": return ToolRefusal("that account's inbox could not be found in the Mail app")
        case "gone": return ToolRefusal("that email is no longer in the inbox")
        default: return nil
        }
    }

    static func rows(from reply: String, now: Date) -> [Row] {
        reply.components(separatedBy: "\u{1E}").dropFirst().compactMap { line in
            let parts = line.components(separatedBy: "\u{1F}")
            guard parts.count == 5, let id = Int(parts[0]), let age = Double(parts[3]) else { return nil }
            return Row(id: id, sender: CalendarFormatter.clean(parts[1]), subject: CalendarFormatter.clean(parts[2]),
                       received: now.addingTimeInterval(-age), unread: parts[4] == "false")
        }
    }

    private static let when: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "EEE d MMM yyyy, HH:mm"
        return formatter
    }()

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        // Never on a model's own idea: only when the user's own words have brought up their email.
        guard access.mail else { throw ToolRefusal("email is read only when the user asks about their email. Do not read it for this") }
        switch tool {
        case "mail_list":
            let rightNow = now()
            // Ninety days back unless the user named a date.
            let usual = rightNow.addingTimeInterval(-Double(Self.defaultDays) * 86_400)
            var since = arguments["since"].flatMap { ToolArguments.moment($0)?.date } ?? usual
            // Further back only when the user's own words named a date, never on a model's say-so alone.
            if !access.anyDate { since = max(since, usual) }
            let until = arguments["until"].flatMap { ToolArguments.moment($0) }.map { $0.hasTime ? $0.date : $0.date.addingTimeInterval(86_400) } ?? rightNow
            let far = arguments["since"] != nil && since < rightNow.addingTimeInterval(-Double(Self.defaultDays) * 86_400)
            let limit = min(max(Int(arguments["limit"] ?? "") ?? 15, 1), 25)
            let from = (arguments["from"] ?? "").lowercased(), about = (arguments["about"] ?? "").lowercased()
            let unreadOnly = arguments["unread"] == "true"
            let (chosen, newlyChosen) = try await account()
            let window = far ? 2_000 : 500
            let reply = try await script(Self.listScript, [chosen, String(window)])
            if let refused = refusal(for: reply, account: chosen) { throw refused }
            let all = Self.rows(from: reply, now: rightNow).sorted { $0.received > $1.received }
            // If the inbox holds more than was looked at, and the oldest looked at is still inside the dates asked for, say so.
            let cutOff = all.count >= window && (all.last?.received ?? since) > since
            var notes = cutOff ? "\n(Only the newest \(window) emails in the inbox were looked at; older ones in this stretch of time were not.)" : ""
            if newlyChosen {
                notes += "\n(This is the first time: OMNIS will read only the inbox of the account called \"\(CalendarFormatter.clean(chosen))\" from now on. "
                    + "Tell the user that, and that typing /mail forget makes it choose again.)"
            }
            let matching = all.filter { row in
                row.received >= since && row.received <= until && (!unreadOnly || row.unread)
                    && (from.isEmpty || row.sender.lowercased().contains(from)) && (about.isEmpty || row.subject.lowercased().contains(about))
            }
            let shown = Array(matching.prefix(limit))
            lock.withLock {
                listed = shown.map(\.id)
                listedAt = rightNow
            }
            guard !shown.isEmpty else { return .read(content: "No emails in the inbox match that." + notes, note: "Checked your inbox") }
            let lines = shown.enumerated().map { index, row in
                "m\(index + 1) | \(row.unread ? "unread" : "read") | \(Self.when.string(from: row.received)) | from \(row.sender) | subject: \(SensitiveText.hidingCodes(inSubject: row.subject))"
            }
            let more = matching.count > shown.count ? "\n(\(matching.count - shown.count) more match; ask for fewer days or a sender to narrow it.)" : ""
            return .read(content: ToolArguments.fenced("From the inbox of the user's email. This lists who wrote and the subject, not what each says; use mail_read for that.",
                                                       lines.joined(separator: "\n") + more) + notes,
                         note: "Read your inbox: \(shown.count == 1 ? "1 email" : "\(shown.count) emails") listed")
        case "mail_read":
            let wanted = (arguments["email"] ?? "").lowercased()
            let id: Int? = lock.withLock {
                guard now().timeIntervalSince(listedAt) < Self.idSeconds, wanted.hasPrefix("m"), let number = Int(wanted.dropFirst()),
                      number >= 1, number <= listed.count else { return nil }
                return listed[number - 1]
            }
            guard let id else { throw ToolRefusal("there is no email \(wanted.prefix(8)) in the last list. Use mail_list again first") }
            let chosen = try await account().name
            let reply = try await script(Self.readScript, [chosen, String(id)])
            if let refused = refusal(for: reply, account: chosen) { throw refused }
            let parts = reply.components(separatedBy: "\u{1F}")
            guard parts.count >= 6, parts[0] == "ok" else { throw ToolRefusal("the Mail app did not hand over that email") }
            let sender = CalendarFormatter.clean(parts[1]), subject = CalendarFormatter.clean(parts[2])
            let received = now().addingTimeInterval(-(Double(parts[3]) ?? 0))
            // Names only: what is in an attachment is not read.
            let files = parts[4].components(separatedBy: "\u{1E}").map { CalendarFormatter.clean($0) }.filter { !$0.isEmpty }.prefix(12)
            // Looked at whole, before anything is cut for length, so wording near the end still hides a code near the start.
            let whole = parts[5...].joined(separator: " ")
            let body = SensitiveText.hidingCodes(inEmail: whole, subject: subject) == SensitiveText.hidden ? SensitiveText.hidden : Self.tidy(whole)
            var text = "From: \(sender)\nSubject: \(SensitiveText.hidingCodes(inSubject: subject))\nReceived: \(Self.when.string(from: received))\n"
            if !files.isEmpty { text += "Attachments (names only; their contents were not read): \(files.joined(separator: ", "))\n" }
            text += "\n" + body
            return .read(content: ToolArguments.fenced("One email from the user's inbox.", text), note: "Read 1 email")
        default:
            throw ToolRefusal("that is not something OMNIS can do with email")
        }
    }

    /// An email's text with its blank space squeezed and its length kept within reason.
    static func tidy(_ text: String) -> String {
        let lines = text.components(separatedBy: .newlines).map { CalendarFormatter.clean($0) }
        var kept: [String] = []
        for line in lines where !(line.isEmpty && kept.last?.isEmpty != false) { kept.append(line) }
        let whole = kept.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return whole.count > maxBodyCharacters ? String(whole.prefix(maxBodyCharacters)) + "\n[The email is longer; the rest was not read.]" : whole
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        throw ToolRefusal("OMNIS only reads email")
    }
}

/// Sign-in codes and reset links are worth more to a thief than anything else
/// in an inbox, and nothing OMNIS does needs them. They are left out before
/// an email's text goes anywhere.
public enum SensitiveText {
    public static let hidden = "[hidden: this looks like a verification code or a sign-in or reset link]"

    // Wording that says the email exists to carry a code or a link for signing in.
    private static let codeWording = try! NSRegularExpression(
        pattern: #"\b((verification|security|confirmation|access|log[- ]?in|sign[- ]?in|authentication|one[- ]time) code|one[- ]time (pass)?(code|word|pin)|passcode|otp|2fa|two[- ]factor|two[- ]step|pin|verify your (email|account|identity|sign|log)\w*|confirm your (email|account|identity)|reset (your|my|the) password|password reset|(temporary|initial|new) password|magic link|sign[- ]in link|your code is|to (sign|log)[- ]?in|to verify)\b"#,
        options: [.caseInsensitive])
    private static let digits = try! NSRegularExpression(pattern: #"(?<![\d/:\-])(?<!\d[.,])(\d[ \-]?){3,7}\d(?![\d/:\-])(?![.,]\d)"#)
    private static let link = try! NSRegularExpression(pattern: #"https?://\S+"#, options: [.caseInsensitive])

    private static func has(_ pattern: NSRegularExpression, _ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    /// A subject is hidden only when it carries the code itself.
    public static func hidingCodes(inSubject subject: String) -> String {
        has(codeWording, subject) && has(digits, subject) ? hidden : subject
    }

    /// An email's text is hidden whole when it is there to carry a code or a sign-in link.
    public static func hidingCodes(inEmail body: String, subject: String) -> String {
        guard has(codeWording, subject) || has(codeWording, body) else { return body }
        return has(digits, body) || has(link, body) ? hidden : body
    }
}
