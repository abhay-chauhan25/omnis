import Contacts
import Foundation

/// One way of reaching a person: a phone number or an address, with the label the user gave it.
public struct ContactHandle: Equatable, Sendable {
    public let label: String
    public let value: String

    public init(label: String, value: String) {
        self.label = label
        self.value = value
    }
}

public struct ContactMatch: Equatable, Sendable {
    public let name: String
    public let handles: [ContactHandle]

    public init(name: String, handles: [ContactHandle]) {
        self.name = name
        self.handles = handles
    }
}

/// The user's contacts, for looking people up by name. Replaced by a stand-in in tests.
public protocol ContactsDirectory: Sendable {
    func find(_ name: String) async throws -> [ContactMatch]
}

/// Hands a message to the Messages app. Replaced by a stand-in in tests.
public protocol MessageSending: Sendable {
    func send(text: String, to handle: String) async throws
}

/// Lets a model prepare a text message for the user to send. It can only
/// prepare: the message goes when the user clicks Send on the preview, which
/// shows who it is going to and every word of it.
///
/// A model names a person; OMNIS finds the number in the user's contacts.
/// The model is never given a full number or address, and cannot supply one.
public final class MessagesTools: AssistantTools, @unchecked Sendable {
    public let service = "messages"
    public let toolNames: Set<String> = ["messages_send"]
    public static let maxCharacters = 600
    public static let maxLines = 12

    /// The message as it will be sent, with nothing in it that the preview
    /// would not show: no invisible or direction-changing characters, no
    /// blank filler characters, no runs of empty lines.
    static func visible(_ raw: String) -> String {
        var kept = String.UnicodeScalarView()
        for scalar in raw.unicodeScalars {
            if scalar == "\n" { kept.append(scalar); continue }
            if scalar == "\t" || scalar == "\r" { kept.append(" "); continue }
            switch scalar.properties.generalCategory {
            case .control, .format, .surrogate, .privateUse, .unassigned, .lineSeparator, .paragraphSeparator: continue
            default: break
            }
            // Fillers that take up no room, and selectors other than the one emoji use.
            if [0x034F, 0x115F, 0x1160, 0x3164, 0xFFA0, 0x2800].contains(scalar.value) { continue }
            if (0x180B...0x180F).contains(scalar.value) || (0xFE00...0xFE0E).contains(scalar.value)
                || (0xE0000...0xE0FFF).contains(scalar.value) { continue }
            kept.append(scalar)
        }
        var text = String(kept)
        while text.contains("\n\n\n") { text = text.replacingOccurrences(of: "\n\n\n", with: "\n\n") }
        return text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
    private let contacts: any ContactsDirectory
    private let sender: any MessageSending
    private let refs = EventRefs(prefix: "c")
    private let lock = NSLock()
    private var choices: [String: (name: String, handle: ContactHandle)] = [:]

    public init(contacts: any ContactsDirectory, sender: any MessageSending) {
        self.contacts = contacts
        self.sender = sender
    }

    /// "mobile, ending 42": enough to tell two numbers apart, not enough to copy.
    static func hint(_ handle: ContactHandle) -> String {
        let label = handle.label.isEmpty ? "" : "\(handle.label), "
        if handle.value.contains("@") {
            let parts = handle.value.split(separator: "@", maxSplits: 1)
            return "\(label)an address at \(parts.last ?? "")"
        }
        return "\(label)ending \(String(handle.value.filter(\.isNumber).suffix(2)))"
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        guard tool == "messages_send" else { throw ToolRefusal("that is not something OMNIS can do with Messages") }
        guard access.sends else {
            throw ToolRefusal("sending a message was not asked for in the user's own message. Ask them to say plainly who to message and what to say")
        }
        let text = Self.visible(arguments["text"] ?? "")
        guard !text.isEmpty else { throw ToolRefusal("the message has no words. Ask the user what to say") }
        // Short enough that the whole of it is in front of the user on the preview.
        guard text.count <= Self.maxCharacters, text.split(separator: "\n", omittingEmptySubsequences: false).count <= Self.maxLines else {
            throw ToolRefusal("the message is too long to send this way (at most \(Self.maxCharacters) characters and \(Self.maxLines) lines). Offer a shorter one")
        }

        let chosen: (name: String, handle: ContactHandle)
        if let ref = arguments["contact"]?.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")), !ref.isEmpty {
            guard let key = refs.key(for: ref), let known = lock.withLock({ choices[key] }) else {
                throw ToolRefusal("that contact id is not known. Look the person up by name first")
            }
            chosen = known
        } else {
            let name = CalendarFormatter.clean(arguments["to"] ?? "")
            guard !name.isEmpty else { throw ToolRefusal("say who the message is for, by their name in the user's contacts") }
            let found = try await contacts.find(name)
            let options = found.flatMap { match in match.handles.map { (name: match.name, handle: $0) } }
            guard !options.isEmpty else {
                throw ToolRefusal("there is nobody called \"\(name)\" with a phone number or address in the user's contacts. Ask the user for the name as it is saved")
            }
            if options.count == 1 {
                chosen = options[0]
            } else {
                // More than one person, or more than one number. The user chooses; the model only relays.
                guard options.count <= 12 else {
                    throw ToolRefusal("too many people or numbers match \"\(name)\". Ask the user for the full name")
                }
                let lines = options.map { option -> String in
                    let key = "\(option.name)|\(option.handle.value)"
                    lock.withLock { choices[key] = option }
                    return "[\(refs.ref(for: key))] \(CalendarFormatter.clean(option.name)), \(Self.hint(option.handle))"
                }
                return .read(content: ToolArguments.fenced(
                    "More than one match in the user's contacts. Ask the user which one they mean, then call messages_send again with "
                    + "that id as contact. Do not choose for them, and do not show the ids.", lines.joined(separator: "\n")),
                             note: "Looked up a contact")
            }
        }
        var rows = [ChangeRow("To", chosen.handle.label.isEmpty ? chosen.handle.value : "\(chosen.handle.value) (\(chosen.handle.label))")]
        rows.append(ChangeRow("Message", text))
        return .proposal(ActionProposal(
            service: service, kind: "send_message", heading: "Send message", title: "To \(CalendarFormatter.clean(chosen.name))", rows: rows,
            warning: "This is sent from your own Messages account and cannot be taken back.",
            confirmLabel: "Send", declineLabel: "Don't Send",
            payload: ["handle": chosen.handle.value, "text": text, "name": chosen.name]))
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        guard proposal.kind == "send_message", let handle = proposal.payload["handle"], let text = proposal.payload["text"],
              !handle.isEmpty, !text.isEmpty else { throw ToolRefusal("there was nothing to send") }
        try await sender.send(text: text, to: handle)
        // Messages does the sending; whether it arrived shows there, not here.
        return "Handed to Messages to send"
    }
}

/// The Mac's contacts through Apple's own interface. The first use makes
/// macOS ask for permission. Only names, numbers and addresses are read.
public final class SystemContacts: ContactsDirectory, @unchecked Sendable {
    public init() {}

    public func find(_ name: String) async throws -> [ContactMatch] {
        let store = CNContactStore()
        if CNContactStore.authorizationStatus(for: .contacts) == .notDetermined {
            _ = try? await store.requestAccess(for: .contacts)
        }
        guard CNContactStore.authorizationStatus(for: .contacts) == .authorized else {
            throw ToolRefusal("OMNIS has not been allowed to look at your contacts. You can allow it in System Settings, under Privacy & Security, Contacts")
        }
        let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName), CNContactPhoneNumbersKey as CNKeyDescriptor,
                    CNContactEmailAddressesKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor]
        let found = try store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: name), keysToFetch: keys)
        return found.prefix(8).compactMap { contact in
            let shown = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.nickname
            guard !shown.isEmpty else { return nil }
            let phones = contact.phoneNumbers.map {
                ContactHandle(label: $0.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "", value: $0.value.stringValue)
            }
            let addresses = contact.emailAddresses.map {
                ContactHandle(label: $0.label.map { CNLabeledValue<NSString>.localizedString(forLabel: $0) } ?? "", value: $0.value as String)
            }
            return ContactMatch(name: shown, handles: phones + addresses)
        }
    }
}

/// Sends through the Messages app, which the user is already signed in to.
/// The script is fixed text. The number and the words are handed to it as
/// separate values and never become part of it.
public struct MessagesAppSender: MessageSending {
    private let runner: CommandRunner
    private static let osascript = URL(fileURLWithPath: "/usr/bin/osascript")
    static let script = """
        on run argv
            set theHandle to item 1 of argv
            set theWords to item 2 of argv
            tell application "Messages"
                -- Finding the person may be tried twice. Sending happens once, below.
                try
                    set thePerson to participant theHandle of (1st account whose service type = iMessage)
                on error
                    set thePerson to participant theHandle of (1st account whose service type = SMS)
                end try
                send theWords to thePerson
            end tell
        end run
        """

    public init(run: @escaping CommandRunner = Commands.system) {
        self.runner = run
    }

    public func send(text: String, to handle: String) async throws {
        // "--" ends osascript's own options, so nothing in a number or a message can be read as one.
        let result = await runner(Self.osascript, ["-e", Self.script, "--", handle, text], nil)
        guard result.status == 0 else {
            throw ToolRefusal(result.output.contains("-1743")
                ? "OMNIS has not been allowed to control Messages. You can allow it in System Settings, under Privacy & Security, Automation"
                : "Messages could not send it")
        }
    }
}
