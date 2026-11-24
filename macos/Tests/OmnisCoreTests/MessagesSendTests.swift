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
        for text in ["text Sam that I'm late", "send a message to mum", "tell Priya I said hi", "let Sam know I'm outside", "reply saying yes"] {
            #expect(PersonalIntent.asksToSend(text), "\(text)")
        }
        for text in ["what's on my calendar", "summarise this file", "who is Sam"] { #expect(!PersonalIntent.asksToSend(text), "\(text)") }
        var chat = Conversation()
        #expect(!chat.serviceAccess(for: "what's on today").sends)
        #expect(chat.serviceAccess(for: "text Sam I'm late").sends)
        #expect(chat.serviceAccess(for: "the mobile one").sends)         // answering "which number?"
        #expect(!chat.serviceAccess(for: "thanks").sends)                 // and no longer after that
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
        // An over-long message is cut or refused; it is never shown as more than the limit.
        let long = try? await messages.run(tool: "messages_send", arguments: ["to": "sam", "text": String(repeating: "x", count: 5000)], access: Self.may)
        if let long, let cut = proposal(long) { #expect((cut.payload["text"] ?? "").count <= MessagesTools.maxCharacters) }
        await #expect(throws: ToolRefusal.self) { try await messages.run(tool: "messages_read", arguments: [:], access: Self.may) }
        #expect(sender.sent.values.isEmpty)
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

        let refused = MessagesAppSender(run: { _, _, _ in CommandResult(status: 1, output: "execution error: Not authorized to send Apple events to Messages. (-1743)") })
        await #expect(throws: ToolRefusal("OMNIS has not been allowed to control Messages. You can allow it in System Settings, under Privacy & Security, Automation")) {
            try await refused.send(text: "hi", to: "+15550100142")
        }
    }
}
