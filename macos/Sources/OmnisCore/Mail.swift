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

    // Every script is fixed text. The account's name, positions, counts, the words searched for and a
    // message's number are handed over beside them, never written into them.
    //
    // Mail answers slowly: measured on the user's inbox of 7,600 emails, about a tenth of a second for each
    // thing asked about each email, however it is asked. So nothing here looks through the inbox. Each
    // script touches a couple of dozen emails at most, and Mail itself does the finding where it can.

    private static let opening = """
    on run arguments
        set wantedAccount to item 1 of arguments
        set secondValue to ""
        set thirdValue to ""
        set fourthValue to ""
        if (count of arguments) > 1 then set secondValue to item 2 of arguments
        if (count of arguments) > 2 then set thirdValue to item 3 of arguments
        if (count of arguments) > 3 then set fourthValue to item 4 of arguments
        set fieldGap to (ASCII character 31)
        set rowGap to (ASCII character 30)
        set unreadOnes to {}
        set knowsUnread to false
        tell application "Mail"
            with timeout of 45 seconds
                set accountNames to name of (every account whose enabled is true)
                if wantedAccount is "" then
                    set answerText to "accounts"
                    repeat with oneName in accountNames
                        set answerText to answerText & fieldGap & oneName
                    end repeat
                    return answerText
                end if
                if accountNames does not contain wantedAccount then return "missing"
                try
                    set theInbox to mailbox "Inbox" of account wantedAccount
                    set inboxCount to count of messages of theInbox
                on error
                    return "nobox"
                end try
                set unreadTotal to unread count of theInbox
    """
    private static let closing = """
        set rightNow to current date
        repeat with i from 1 to count of gotNumbers
            set thisNumber to item i of gotNumbers
            set readWord to "unknown"
            if knowsUnread then set readWord to ((unreadOnes does not contain thisNumber) as string)
            set answerText to answerText & rowGap & thisNumber & fieldGap & (item i of gotSenders) & fieldGap & (item i of gotSubjects) & fieldGap & ((rightNow - (item i of gotDates)) as integer) & fieldGap & readWord
        end repeat
        return answerText
    end run
    """
    // Which emails are unread is asked of Mail once, as a short list, when there are few enough for that to be quick.
    private static let unreadLookup = """
                if unreadTotal < 151 then
                    set unreadOnes to id of (messages of theInbox whose read status is false)
                    set knowsUnread to true
                end if
    """

    /// Emails by where they sit in the inbox, newest first: so many, starting at a position.
    /// With no account named, the names of the accounts that are switched on in Mail.
    static let rangeScript = opening + """

                set startAt to secondValue as integer
                set howMany to thirdValue as integer
                set answerText to "ok" & fieldGap & inboxCount & fieldGap & unreadTotal
                if inboxCount < startAt then return answerText
                set endAt to startAt + howMany - 1
                if endAt > inboxCount then set endAt to inboxCount
                set gotNumbers to id of messages startAt thru endAt of theInbox
                set gotSenders to sender of messages startAt thru endAt of theInbox
                set gotSubjects to subject of messages startAt thru endAt of theInbox
                set gotDates to date received of messages startAt thru endAt of theInbox

    """ + unreadLookup + """

            end timeout
        end tell

    """ + closing

    /// Emails Mail itself finds: the unread ones, or those whose sender or subject contains some words.
    /// If more match than can be fetched in time, only how many is reported.
    static let findScript = opening + """

                set whichSearch to secondValue
                set searchWords to thirdValue
                set howMany to fourthValue as integer
                if whichSearch is "unread" then
                    if unreadTotal > howMany then return "many" & fieldGap & unreadTotal
                    set gotNumbers to id of (messages of theInbox whose read status is false)
                    set gotSenders to sender of (messages of theInbox whose read status is false)
                    set gotSubjects to subject of (messages of theInbox whose read status is false)
                    set gotDates to date received of (messages of theInbox whose read status is false)
                    set unreadOnes to gotNumbers
                    set knowsUnread to true
                else if whichSearch is "sender" then
                    set matchCount to count of (messages of theInbox whose sender contains searchWords)
                    if matchCount > howMany then return "many" & fieldGap & matchCount
                    set gotNumbers to id of (messages of theInbox whose sender contains searchWords)
                    set gotSenders to sender of (messages of theInbox whose sender contains searchWords)
                    set gotSubjects to subject of (messages of theInbox whose sender contains searchWords)
                    set gotDates to date received of (messages of theInbox whose sender contains searchWords)
                else
                    set matchCount to count of (messages of theInbox whose subject contains searchWords)
                    if matchCount > howMany then return "many" & fieldGap & matchCount
                    set gotNumbers to id of (messages of theInbox whose subject contains searchWords)
                    set gotSenders to sender of (messages of theInbox whose subject contains searchWords)
                    set gotSubjects to subject of (messages of theInbox whose subject contains searchWords)
                    set gotDates to date received of (messages of theInbox whose subject contains searchWords)
                end if
                set answerText to "ok" & fieldGap & inboxCount & fieldGap & unreadTotal
                if whichSearch is not "unread" then

    """ + unreadLookup.replacingOccurrences(of: "\n            ", with: "\n                ") + """

                end if
            end timeout
        end tell

    """ + closing

    /// Where in the inbox a moment in time falls: the position of the first email that old or older.
    /// The inbox is in order of arrival, so this is found in a dozen looks rather than by reading it all.
    static let positionScript = opening + """

                set ageWanted to secondValue as integer
                set rightNow to current date
                set nearEnd to 1
                set farEnd to inboxCount + 1
                repeat while nearEnd < farEnd
                    set halfWay to (nearEnd + farEnd) div 2
                    if ((rightNow - (date received of message halfWay of theInbox)) as integer) < ageWanted then
                        set nearEnd to halfWay + 1
                    else
                        set farEnd to halfWay
                    end if
                end repeat
                return "ok" & fieldGap & nearEnd
            end timeout
        end tell
    end run
    """

    /// One message: sender, subject, age in seconds, the names of its attachments, and its text.
    static let readScript = """
    on run arguments
        set wantedAccount to item 1 of arguments
        set emailNumber to (item 2 of arguments) as integer
        set fieldGap to (ASCII character 31)
        set rowGap to (ASCII character 30)
        tell application "Mail"
            with timeout of 40 seconds
                try
                    set theInbox to mailbox "Inbox" of account wantedAccount
                on error
                    return "nobox"
                end try
                set theMatches to (messages of theInbox whose id is emailNumber)
                if (count of theMatches) is 0 then return "gone"
                set theEmail to item 1 of theMatches
                set fileList to ""
                try
                    repeat with thisFile in (mail attachments of theEmail)
                        set fileList to fileList & (name of thisFile) & rowGap
                    end repeat
                end try
                set emailText to (content of theEmail) as string
                if (count of emailText) > 12000 then set emailText to text 1 thru 12000 of emailText
                return "ok" & fieldGap & (sender of theEmail) & fieldGap & (subject of theEmail) & fieldGap & (((current date) - (date received of theEmail)) as integer) & fieldGap & fileList & fieldGap & emailText
            end timeout
        end tell
    end run
    """

    /// Development aid: how long each of the real requests to Mail takes on this Mac. It reports
    /// times and counts only, never a sender, a subject or any text.
    public static func timings(run: @escaping CommandRunner = Commands.system, defaults: UserDefaults = .standard) async -> [String] {
        func time(_ name: String, _ text: String, _ arguments: [String]) async -> String {
            let began = Date()
            let result = await run(osascript, ["-e", text, "--"] + arguments, nil)
            let took = String(format: "%.1f s", Date().timeIntervalSince(began))
            let out = result.output.trimmingCharacters(in: .newlines)
            guard result.status == 0 else { return "\(name): \(took), failed (\(out.replacingOccurrences(of: "\n", with: " ").prefix(220)))" }
            // What came back is described, not shown: its kind, and how many emails.
            let kind = out.components(separatedBy: "\u{1F}").first ?? ""
            let many = tooMany(out).map { ", \($0) matched" } ?? ""
            return "\(name): \(took), \(kind)\(many), \(rows(from: out, now: Date()).count) emails"
        }
        guard let account = defaults.string(forKey: accountKey) else { return ["no account has been chosen yet"] }
        var lines: [String] = []
        lines.append(await time("newest 10", rangeScript, [account, "1", "10"]))
        lines.append(await time("newest 25", rangeScript, [account, "1", "25"]))
        lines.append(await time("unread", findScript, [account, "unread", "", String(mostFound)]))
        lines.append(await time("a broad sender", findScript, [account, "sender", "edu", String(mostFound)]))
        lines.append(await time("a narrow subject", findScript, [account, "subject", "meeting", String(mostFound)]))
        lines.append(await time("jump to 30 days ago", positionScript, [account, String(30 * 86_400)]))
        lines.append(await time("10 emails from 30 days ago", rangeScript, [account, "400", "10"]))
        // Reading one email: the newest, by its number. Only how long it took is reported.
        let newest = await run(osascript, ["-e", rangeScript, "--", account, "1", "1"], nil)
        if let number = rows(from: newest.output.trimmingCharacters(in: .newlines), now: Date()).first?.id {
            let began = Date()
            let result = await run(osascript, ["-e", readScript, "--", account, String(number)], nil)
            let kind = result.output.components(separatedBy: "\u{1F}").first ?? ""
            lines.append(String(format: "read one email: %.1f s, ", Date().timeIntervalSince(began))
                + (result.status == 0 ? "\(kind), \(result.output.count) characters" : "failed (\(result.output.replacingOccurrences(of: "\n", with: " ").prefix(220)))"))
        }
        return lines
    }

    struct Row: Equatable {
        let id: Int
        let sender: String
        let subject: String
        let received: Date
        /// Nil when Mail was not asked, because finding out would have taken too long.
        let unread: Bool?
    }

    /// How many emails a list can show, and how many matches Mail is asked to fetch before the user is asked to narrow it.
    static let mostListed = 25
    static let mostFound = 40

    /// How many emails matched, when Mail said there were too many to fetch.
    static func tooMany(_ reply: String) -> Int? {
        let parts = reply.components(separatedBy: "\u{1F}")
        return parts.first == "many" && parts.count > 1 ? Int(parts[1]) : nil
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
        let parts = try await script(Self.rangeScript, ["", "1", "0"]).components(separatedBy: "\u{1F}")
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
                       received: now.addingTimeInterval(-age), unread: parts[4] == "unknown" ? nil : parts[4] == "false")
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
            let usual = rightNow.addingTimeInterval(-Double(Self.defaultDays) * 86_400)
            var since = arguments["since"].flatMap { ToolArguments.moment($0)?.date } ?? usual
            // Further back only when the user's own words named a date, never on a model's say-so alone.
            if !access.anyDate { since = max(since, usual) }
            let untilGiven = arguments["until"].flatMap { ToolArguments.moment($0) }.map { $0.hasTime ? $0.date : $0.date.addingTimeInterval(86_400) }
            let until = min(untilGiven ?? rightNow, rightNow)
            let limit = min(max(Int(arguments["limit"] ?? "") ?? 10, 1), Self.mostListed)
            let from = CalendarFormatter.clean(arguments["from"] ?? ""), about = CalendarFormatter.clean(arguments["about"] ?? "")
            let unreadOnly = arguments["unread"] == "true"
            let (chosen, newlyChosen) = try await account()
            var notes = ""
            var reply: String
            if !from.isEmpty || !about.isEmpty {
                // Mail does the finding. One of the two is searched for there; the other is checked here.
                let bySender = !from.isEmpty
                reply = try await script(Self.findScript, [chosen, bySender ? "sender" : "subject", String((bySender ? from : about).prefix(80)), String(Self.mostFound)])
                if let many = Self.tooMany(reply) {
                    throw ToolRefusal("\(many) emails in the inbox match that, too many to go through in the time Mail allows. "
                        + "Ask the user for something narrower: a fuller name, or particular words from the subject")
                }
            } else if unreadOnly {
                reply = try await script(Self.findScript, [chosen, "unread", "", String(Self.mostFound)])
                if let many = Self.tooMany(reply) {
                    // Too many unread to fetch them all: the unread among the newest emails are shown instead.
                    reply = try await script(Self.rangeScript, [chosen, "1", String(Self.mostListed)])
                    notes += "\n(\(many) emails are unread in all. These are the unread ones among the newest \(Self.mostListed).)"
                }
            } else {
                // The newest, or the newest up to a day the user named: found by position, not by reading the inbox.
                var first = 1
                if untilGiven != nil, until < rightNow {
                    let found = try await script(Self.positionScript, [chosen, String(Int(rightNow.timeIntervalSince(until)))])
                    if let refused = refusal(for: found, account: chosen) { throw refused }
                    first = Int(found.components(separatedBy: "\u{1F}").dropFirst().first ?? "") ?? 1
                }
                reply = try await script(Self.rangeScript, [chosen, String(first), String(limit)])
            }
            if let refused = refusal(for: reply, account: chosen) { throw refused }
            let header = (reply.components(separatedBy: "\u{1E}").first ?? "").components(separatedBy: "\u{1F}")
            let unreadInAll = header.count > 2 ? Int(header[2]) : nil
            let matching = Self.rows(from: reply, now: rightNow).sorted { $0.received > $1.received }.filter { row in
                row.received >= since && row.received <= until && (!unreadOnly || row.unread == true)
                    && (from.isEmpty || row.sender.lowercased().contains(from.lowercased()))
                    && (about.isEmpty || row.subject.lowercased().contains(about.lowercased()))
            }
            let shown = Array(matching.prefix(limit))
            lock.withLock {
                listed = shown.map(\.id)
                listedAt = rightNow
            }
            if let unreadInAll { notes += "\n(\(unreadInAll) unread in the inbox in all.)" }
            if newlyChosen {
                notes += "\n(This is the first time: OMNIS will read only the inbox of the account called \"\(CalendarFormatter.clean(chosen))\" from now on. "
                    + "Tell the user that, and that typing /mail forget makes it choose again.)"
            }
            guard !shown.isEmpty else { return .read(content: "No emails in the inbox match that." + notes, note: "Checked your inbox") }
            let lines = shown.enumerated().map { index, row in
                let state = row.unread.map { $0 ? "unread" : "read" } ?? "read or unread not known"
                return "m\(index + 1) | \(state) | \(Self.when.string(from: row.received)) | from \(row.sender) | subject: \(SensitiveText.hidingCodes(inSubject: row.subject))"
            }
            let more = matching.count > shown.count ? "\n(\(matching.count - shown.count) more match.)" : ""
            return .read(content: ToolArguments.fenced("From the inbox of the user's email, newest first. This lists who wrote and the subject, not what each says; use mail_read for that.",
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
