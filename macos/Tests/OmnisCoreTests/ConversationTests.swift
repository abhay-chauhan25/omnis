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

    @Test func aLongChatSendsOnlyTheMostRecentWholeExchanges() {
        var chat = Conversation()
        for index in 0..<40 {
            let id = chat.begin(question: "q\(index)")
            chat.update(id) { $0.text = "a\(index)"; $0.state = .done }
        }
        let history = chat.history()
        #expect(history.count == Conversation.maxHistoryMessages)
        #expect(history.first == ChatTurn(role: .user, content: "q28"))
        #expect(history.last == ChatTurn(role: .assistant, content: "a39"))

        // Size is limited too, and an exchange is kept whole or not at all.
        var big = Conversation()
        for index in 0..<6 {
            let id = big.begin(question: "question \(index)")
            big.update(id) { $0.text = String(repeating: "x", count: 5_000); $0.state = .done }
        }
        let trimmed = big.history()
        #expect(trimmed.count == 4)
        #expect(trimmed.first?.content == "question 4")
        #expect(trimmed.map(\.content.count).reduce(0, +) <= Conversation.maxHistoryCharacters)

        // One exchange too big to send leaves nothing, never half an exchange.
        var huge = Conversation()
        let id = huge.begin(question: String(repeating: "y", count: 30_000))
        huge.update(id) { $0.text = "short"; $0.state = .done }
        #expect(huge.history().isEmpty)
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

@Suite struct ConversationLocalRuleTests {
    @Test func keepingOneTurnLocalKeepsTheChatLocalUntilANewChat() {
        var chat = Conversation()
        #expect(!chat.staysLocal)
        let id = chat.begin(question: "private thing")
        chat.keepLocal()
        chat.update(id) { $0.text = "ok"; $0.state = .done }
        _ = chat.begin(question: "a public follow-up")
        #expect(chat.staysLocal)
        chat.clear()
        #expect(!chat.staysLocal)
    }
}

@Suite struct ConversationSearchConsentTests {
    @Test func theAnswerHoldsForTheChatAndANewChatForgetsIt() {
        var chat = Conversation()
        #expect(chat.searchConsent == .notAsked)
        let id = chat.begin(question: "what is on today, and look up the venue")
        chat.update(id) { $0.searchAsk = SearchAsk(query: "venue opening hours") }
        chat.settleSearch(allowed: true)
        #expect(chat.searchConsent == .allowed)
        #expect(chat.messages.last?.searchAsk?.state == .allowed)
        chat.clear()
        #expect(chat.searchConsent == .notAsked)

        let second = chat.begin(question: "again")
        chat.update(second) { $0.searchAsk = SearchAsk(query: "q") }
        chat.settleSearch(allowed: false)
        #expect(chat.searchConsent == .refused && chat.messages.last?.searchAsk?.state == .declined)
    }

    @Test func anUnansweredQuestionDecidesNothing() {
        var chat = Conversation()
        let id = chat.begin(question: "look it up")
        chat.update(id) { $0.searchAsk = SearchAsk(query: "q") }
        chat.lapseSearchAsk()
        #expect(chat.messages.last?.searchAsk?.state == .lapsed)
        #expect(chat.searchConsent == .notAsked)
        // A settled card is not reopened by a later lapse.
        chat.update(id) { $0.searchAsk = SearchAsk(query: "q", state: .allowed) }
        chat.lapseSearchAsk()
        #expect(chat.messages.last?.searchAsk?.state == .allowed)
    }
}
