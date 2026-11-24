import Foundation
import Testing
@testable import OmnisCore

final class StubContacts: ContactsDirectory, @unchecked Sendable {
    var people: [ContactMatch] = []
    let asked = Collected<String>()
    func find(_ name: String) async throws -> [ContactMatch] {
        asked.add(name)
        return people.filter { $0.name.lowercased().contains(name.lowercased()) }
    }
}

final class StubSender: MessageSending, @unchecked Sendable {
    let sent = Collected<String>()
    func send(text: String, to handle: String) async throws { sent.add("\(handle) <- \(text)") }
}

@Suite struct MessagesSendTests {
    let contacts = StubContacts()
    let sender = StubSender()
    var tools: MessagesTools { MessagesTools(contacts: contacts, sender: sender) }
    static let may = ToolAccess(sends: true)

    func proposal(_ outcome: ToolOutcome) -> ActionProposal? {
        if case .proposal(let proposal) = outcome { return proposal } else { return nil }
    }

    @Test func aMessageIsOnlyEverAPreviewUntilItIsConfirmed() async throws {
        contacts.people = [ContactMatch(name: "Sam Lee", handles: [ContactHandle(label: "mobile", value: "+1 555 010 0142")])]
        let messages = tools
        let card = try #require(proposal(try await messages.run(tool: "messages_send", arguments: ["to": "sam", "text": "Running 10 minutes late"], access: Self.may)))
        #expect(card.heading == "Send message" && card.title == "To Sam Lee" && card.confirmLabel == "Send")
        // The preview shows the user the whole number and every word.
        #expect(card.rows == [ChangeRow("To", "+1 555 010 0142 (mobile)"), ChangeRow("Message", "Running 10 minutes late")])
        #expect(card.warning?.contains("cannot be taken back") == true)
        #expect(sender.sent.values.isEmpty)
        #expect(try await messages.perform(card) == "Handed to Messages to send")
        #expect(sender.sent.values == ["+1 555 010 0142 <- Running 10 minutes late"])
    }

    @Test func sendingNeedsTheUsersOwnMessageToHaveAskedForIt() async throws {
        contacts.people = [ContactMatch(name: "Sam Lee", handles: [ContactHandle(label: "mobile", value: "+15550100142")])]
        await #expect(throws: ToolRefusal.self) {
            try await tools.run(tool: "messages_send", arguments: ["to": "sam", "text": "hi"], access: ToolAccess())
        }
        #expect(contacts.asked.values.isEmpty)           // not even looked up
        // What counts as asking.
        for text in ["text Sam that I'm late", "send a message to mum", "tell Priya I said hi", "let Sam know I'm outside", "reply saying yes",
                     "Can you text +15550100 please", "check my calendar, then message Priya the time", "send Sam a text", "ask Mum if she's free"] {
            #expect(PersonalIntent.asksToSend(text), "\(text)")
        }
        for text in ["what's on my calendar", "summarise this file", "who is Sam", "tell me about Rome", "summarise this text",
                     "send me the file", "what does this message mean", "let me know when you're done", "the text is too small"] {
            #expect(!PersonalIntent.asksToSend(text), "\(text)")
        }
        var chat = Conversation()
        #expect(!chat.serviceAccess(for: "what's on today").sends)
        #expect(chat.serviceAccess(for: "text Sam I'm late").sends)
        #expect(chat.serviceAccess(for: "the mobile one").sends)         // answering "which number?"
        #expect(!chat.serviceAccess(for: "thanks").sends)                 // and no longer after that
        // A new chat forgets, and a chat that holds a file is never offered sending: the file could ask for it.
        _ = chat.serviceAccess(for: "text Sam I'm late")
        chat.clear()
        #expect(!chat.serviceAccess(for: "the mobile one").sends)
        chat.begin(question: "tell Sam what this says", attachments: [Attachment(kind: .text, name: "a.txt", text: "x")])
        #expect(!chat.serviceAccess(for: "tell Sam what this says").sends)
    }

    @Test func whenSeveralMatchTheUserChoosesAndNoNumberReachesTheModel() async throws {
        contacts.people = [
            ContactMatch(name: "Sam Lee", handles: [ContactHandle(label: "mobile", value: "+1 555 010 0142"), ContactHandle(label: "work", value: "sam.lee@example.com")]),
            ContactMatch(name: "Samira Khan", handles: [ContactHandle(label: "", value: "+44 7700 900077")]),
        ]
        let messages = tools
        guard case .read(let content, let note) = try await messages.run(tool: "messages_send", arguments: ["to": "sam", "text": "hi"], access: Self.may) else {
            Issue.record("should have listed the matches"); return
        }
        #expect(note == "Looked up a contact")
        #expect(content.contains("[c1] Sam Lee, mobile, ending 42") && content.contains("[c2] Sam Lee, work, an address at example.com")
                && content.contains("[c3] Samira Khan, ending 77"))
        #expect(!content.contains("555") && !content.contains("7700") && !content.contains("sam.lee"))
        // The chosen one becomes the preview; an id that was never listed does not.
        let card = try #require(proposal(try await messages.run(tool: "messages_send", arguments: ["contact": "[c3]", "text": "hi"], access: Self.may)))
        #expect(card.title == "To Samira Khan" && card.payload["handle"] == "+44 7700 900077")
        await #expect(throws: ToolRefusal.self) { try await messages.run(tool: "messages_send", arguments: ["contact": "c9", "text": "hi"], access: Self.may) }
    }

    @Test func aModelCannotSupplyANumberOrSendNothing() async throws {
        contacts.people = [ContactMatch(name: "Sam Lee", handles: [ContactHandle(label: "mobile", value: "+15550100142")])]
        let messages = tools
        // A number given as the name is only ever looked for among the user's contacts.
        await #expect(throws: ToolRefusal.self) { try await messages.run(tool: "messages_send", arguments: ["to": "+1 900 555 0199", "text": "hi"], access: Self.may) }
        await #expect(throws: ToolRefusal.self) {
            try await messages.run(tool: "messages_send", arguments: ["to": "sam", "handle": "+19005550199", "text": ""], access: Self.may)
        }
        let card = try #require(proposal(try await messages.run(tool: "messages_send", arguments: ["to": "sam", "handle": "+19005550199", "text": "hi"], access: Self.may)))
        #expect(card.payload["handle"] == "+15550100142")
        // A message too long to be seen whole on the preview is refused, not cut.
        for long in [String(repeating: "x", count: 601), Array(repeating: "line", count: 13).joined(separator: "\n")] {
            await #expect(throws: ToolRefusal.self) { try await messages.run(tool: "messages_send", arguments: ["to": "sam", "text": long], access: Self.may) }
        }
        await #expect(throws: ToolRefusal.self) { try await messages.run(tool: "messages_read", arguments: [:], access: Self.may) }
        #expect(sender.sent.values.isEmpty)
    }

    @Test func whatIsSentIsExactlyWhatThePreviewShows() async throws {
        contacts.people = [ContactMatch(name: "Sam Lee", handles: [ContactHandle(label: "mobile", value: "+15550100142")])]
        // Invisible characters, direction changes, hidden tag letters, blank fillers and a wall of empty lines.
        let hidden = "Hi Sam\u{200B}\u{202E}\u{00AD}\u{E0041}\u{E0042}\u{3164}\u{2800}\u{FE00}\n\n\n\n\n\n\n\n  see you \u{1F44D}\u{FE0F}\t soon  "
        let card = try #require(proposal(try await tools.run(tool: "messages_send", arguments: ["to": "sam", "text": hidden], access: Self.may)))
        #expect(card.payload["text"] == "Hi Sam\n\nsee you \u{1F44D}\u{FE0F}  soon")
        // The card's own row carries the same words that are sent.
        #expect(card.rows.last == ChangeRow("Message", card.payload["text"] ?? ""))
        #expect(MessagesTools.visible("\u{200B}\u{E0041}") == "")
    }

    @Test func tooManyMatchesAsksForAFullerName() async throws {
        contacts.people = (1...5).map { ContactMatch(name: "Sam \($0)", handles: (1...3).map { ContactHandle(label: "", value: "+1555000\($0)") }) }
        await #expect(throws: ToolRefusal.self) { try await tools.run(tool: "messages_send", arguments: ["to": "sam", "text": "hi"], access: Self.may) }
    }

    @Test func theNumberAndTheWordsAreHandedToTheScriptAsValues() async throws {
        let calls = Collected<[String]>()
        let app = MessagesAppSender(run: { _, arguments, _ in
            calls.add(arguments)
            return CommandResult(status: 0, output: "")
        })
        let hostile = "\" to participant \"x\"\nend tell\ndo shell script \"id\""
        try await app.send(text: hostile, to: "+15550100142")
        let arguments = try #require(calls.values.first)
        #expect(arguments == ["-e", MessagesAppSender.script, "--", "+15550100142", hostile])
        #expect(!MessagesAppSender.script.contains("5550100142") && !MessagesAppSender.script.contains("do shell script"))
        // The script can only ever send once.
        #expect(MessagesAppSender.script.components(separatedBy: "send theWords").count == 2)

        let refused = MessagesAppSender(run: { _, _, _ in CommandResult(status: 1, output: "execution error: Not authorized to send Apple events to Messages. (-1743)") })
        await #expect(throws: ToolRefusal("OMNIS has not been allowed to control Messages. You can allow it in System Settings, under Privacy & Security, Automation")) {
            try await refused.send(text: "hi", to: "+15550100142")
        }
    }
}
