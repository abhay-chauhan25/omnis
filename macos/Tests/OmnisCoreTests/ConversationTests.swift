import Foundation
import Testing
@testable import OmnisCore

@Suite struct ConversationTests {
    @Test func aQuestionAddsTheMessageAndAnAnswerToFill() {
        var chat = Conversation()
        #expect(chat.isEmpty)
        let id = chat.begin(question: "who won the grand prix")
        #expect(chat.messages.count == 2)
        #expect(chat.messages[0].role == .user)
        #expect(chat.messages[1].state == .streaming)
        #expect(chat.isAnswering)

        chat.update(id) { $0.text += "Lando " }
        chat.update(id) { $0.text += "Norris."; $0.state = .done }
        #expect(chat.messages[1].text == "Lando Norris.")
        #expect(!chat.isAnswering)
    }

    @Test func historyHoldsOnlyFinishedExchanges() {
        var chat = Conversation()
        let first = chat.begin(question: "q1")
        chat.update(first) { $0.text = "a1"; $0.state = .done }
        let failed = chat.begin(question: "q2")
        chat.update(failed) { $0.state = .failed("backend stopped") }
        let stopped = chat.begin(question: "q3")
        chat.update(stopped) { $0.text = "partial"; $0.state = .stopped }
        let empty = chat.begin(question: "q4")
        chat.update(empty) { $0.text = "   "; $0.state = .done }
        _ = chat.begin(question: "q5")  // still being answered

        #expect(chat.history() == [
            ChatTurn(role: .user, content: "q1"), ChatTurn(role: .assistant, content: "a1"),
            ChatTurn(role: .user, content: "q3"), ChatTurn(role: .assistant, content: "partial"),
        ])
    }

    @Test func historyAlwaysAlternatesUserThenAssistant() {
        var chat = Conversation()
        for index in 0..<5 {
            let id = chat.begin(question: "q\(index)")
            chat.update(id) { $0.text = "a\(index)"; $0.state = index == 2 ? .failed("x") : .done }
        }
        let roles = chat.history().map(\.role)
        #expect(roles.count == 8)
        for (index, role) in roles.enumerated() {
            #expect(role == (index.isMultiple(of: 2) ? .user : .assistant))
        }
    }

    @Test func aNewChatForgetsEverythingAndLateUpdatesAreIgnored() {
        var chat = Conversation()
        let id = chat.begin(question: "private thing")
        chat.clear()
        chat.update(id) { $0.text = "late answer" }  // must not reappear
        #expect(chat.isEmpty)
        #expect(chat.history().isEmpty)
    }
}

@Suite struct AnswerBlocksTests {
    @Test func readsHeadingsListsAndParagraphs() {
        let text = """
        ## Podium
        1. Lando Norris
        2) Max Verstappen

        - first point
        * second point

        A closing line
        that wraps.
        """
        #expect(AnswerBlocks.parse(text) == [
            .heading(level: 2, text: "Podium"),
            .numbered(number: "1", text: "Lando Norris"),
            .numbered(number: "2", text: "Max Verstappen"),
            .bullet("first point"),
            .bullet("second point"),
            .paragraph("A closing line\nthat wraps."),
        ])
    }

    @Test func codeBlocksKeepTheirLinesAndIndentation() {
        let text = "Here:\n```python\ndef f():\n    return 1\n```\nDone."
        #expect(AnswerBlocks.parse(text) == [
            .paragraph("Here:"), .code("def f():\n    return 1"), .paragraph("Done."),
        ])
        // An answer still arriving may stop inside a code block.
        #expect(AnswerBlocks.parse("```\nlet x = 1") == [.code("let x = 1")])
    }

    @Test func thingsThatOnlyLookLikeListsStayAsText() {
        #expect(AnswerBlocks.parse("2026 was a good year") == [.paragraph("2026 was a good year")])
        #expect(AnswerBlocks.parse("-5 degrees") == [.paragraph("-5 degrees")])
        #expect(AnswerBlocks.parse("#hashtag") == [.paragraph("#hashtag")])
        #expect(AnswerBlocks.parse("3.14 is pi") == [.paragraph("3.14 is pi")])
        #expect(AnswerBlocks.parse("**bold** start") == [.paragraph("**bold** start")])
        #expect(AnswerBlocks.parse("").isEmpty)
        #expect(AnswerBlocks.parse("\n\n  \n").isEmpty)
    }

    @Test func linksInsideListItemsAreStillNotClickable() {
        guard case .bullet(let item)? = AnswerBlocks.parse("- see [this](file:///etc/passwd)").first else {
            Issue.record("expected a bullet"); return
        }
        #expect(AnswerFormatter.format(item).runs.allSatisfy { $0.link == nil })
    }
}
