import Foundation
import Testing
@testable import OmnisCore

@Suite struct QueryParserTests {
    @Test func stripsVerbAndAppWord() {
        #expect(QueryParser.parse("open ChatGpt Classic app") == ParsedQuery(core: "chatgpt classic", hintedKind: .app))
    }

    @Test func stripsEditorPhraseAndProjectWord() {
        #expect(QueryParser.parse("open Voyager project in vs code") == ParsedQuery(core: "voyager", hintedKind: .project))
        #expect(QueryParser.parse("Open VoyagerAI in VSCode").core == "voyagerai")
        #expect(QueryParser.parse("launch omnis with Visual Studio Code") == ParsedQuery(core: "omnis", hintedKind: .project))
    }

    @Test func plainNameIsUntouched() {
        #expect(QueryParser.parse("Ghidra") == ParsedQuery(core: "ghidra", hintedKind: nil))
        #expect(QueryParser.parse("open Ghidra") == ParsedQuery(core: "ghidra", hintedKind: nil))
    }

    @Test func fillerWordsAloneAreKeptAsTheName() {
        // While typing, "open" on its own may be the start of an app name.
        #expect(QueryParser.parse("open").core == "open")
        #expect(QueryParser.parse("app").core == "app")
        #expect(QueryParser.parse("open code").core == "code")
    }

    @Test func punctuationAndCaseAreIgnored() {
        #expect(QueryParser.parse("  OPEN   the  Chat-GPT!! ").core == "chat gpt")
        #expect(QueryParser.parse("").core == "")
        #expect(QueryParser.parse("?!").core == "")
    }
}

@Suite struct MatcherTests {
    let registry = sampleRegistry()

    func names(_ query: String) -> [String] {
        Matcher.rank(query: query, registry: registry).map(\.entry.name)
    }

    @Test func theThreeEverydayCommands() {
        #expect(Matcher.rank(query: "open Ghidra", registry: registry).first?.entry.id == "launcher:Ghidra")
        #expect(Matcher.rank(query: "open ChatGpt Classic app", registry: registry).first?.entry.id == "app:ChatGPT Classic")
        #expect(Matcher.rank(query: "open Voyager project in vs code", registry: registry).first?.entry.id == "project:VoyagerAI")
    }

    @Test func voyagerPrefersTheAliasButStillListsTheOther() {
        #expect(names("voyager") == ["VoyagerAI", "Voyagers"])
        #expect(names("voy").prefix(2) == ["VoyagerAI", "Voyagers"])
    }

    @Test func withoutAnAliasTheCloserNameWins() {
        let plain = sampleRegistry(aliases: [:])
        let ranked = Matcher.rank(query: "voyager", registry: plain).map(\.entry.name)
        #expect(ranked == ["Voyagers", "VoyagerAI"])
    }

    @Test func exactNameBeatsAnAliasPrefix() {
        #expect(names("voyagers").first == "Voyagers")
    }

    @Test func partialTypingFindsThings() {
        #expect(names("chat").first == "ChatGPT Classic")
        #expect(names("gh").first == "Ghidra")
        #expect(names("classic") == ["ChatGPT Classic"])
        #expect(names("sys set") == ["System Settings"])
        #expect(names("studio") == ["Visual Studio Code"])
        #expect(names("chatgptclassic") == ["ChatGPT Classic"])
    }

    @Test func wordingCanSteerTheKind() {
        // "vo" fits two projects and one app; saying "app" lifts the app.
        #expect(names("vo app").first == "Voice Memos")
        #expect(names("vo project").first == "VoyagerAI")
        #expect(names("vo app") == ["Voice Memos", "VoyagerAI", "Voyagers"])
    }

    @Test func questionsAndNonsenseMatchNothing() {
        #expect(names("what is on my calendar today").isEmpty)
        #expect(names("zzqx").isEmpty)
        #expect(names("").isEmpty)
        #expect(names("   ").isEmpty)
    }

    @Test func resultsAreCappedAndStable() {
        let many = Registry(
            entries: (1...20).map { RegistryEntry(kind: .app, name: "Tool \($0)", url: URL(fileURLWithPath: "/Applications/Tool \($0).app")) },
            editor: vsCode
        )
        let first = Matcher.rank(query: "tool", registry: many)
        #expect(first.count == 6)
        #expect(first == Matcher.rank(query: "tool", registry: many))
    }
}

@Suite struct LaunchSuggestionTests {
    let registry = sampleRegistry()

    func suggest(_ text: String) -> LaunchSuggestion { LaunchSuggestion.suggest(for: text, registry: registry) }

    @Test func clearLaunchWordingIsPreselected() {
        for text in ["open Ghidra", "open ChatGpt Classic app", "open Voyager project in vs code",
                     "launch safari", "ghidra", "Safari", "voyager", "ChatGPT Classic"] {
            let suggestion = suggest(text)
            #expect(suggestion.preselect, "\(text) should launch on Enter")
            #expect(!suggestion.entries.isEmpty)
        }
        #expect(suggest("open Voyager project in vs code").entries.first?.id == "project:VoyagerAI")
    }

    @Test func politeWordingStillCountsAsALaunch() {
        for text in ["can you open safari", "please open safari", "open safari please", "open up safari",
                     "could you please launch xcode", "hey omnis open ghidra now"] {
            let suggestion = suggest(text)
            #expect(suggestion.preselect, "\(text) should launch on Enter")
            #expect(suggestion.entries.first != nil)
        }
        #expect(suggest("can you open safari").entries.first?.name == "Safari")
        #expect(suggest("open up safari").entries.first?.name == "Safari")
        // A request that asks for more than a launch is still a message.
        for text in ["open xcode and explain swift", "can you explain safari", "please help"] {
            #expect(!suggest(text).preselect, "\(text) should be sent as a message")
        }
    }

    @Test func partialNamesAreOfferedButEnterStillSendsAMessage() {
        for text in ["voy", "chat", "sys", "calc", "x"] {
            let suggestion = suggest(text)
            #expect(!suggestion.preselect, "\(text) should send as a message on Enter")
        }
        #expect(suggest("voy").entries.map(\.name).prefix(2) == ["VoyagerAI", "Voyagers"])
    }

    @Test func ordinaryMessagesOfferNothing() {
        for text in ["hi", "what is the capital of France", "who won the grand prix",
                     "and who came second?", "open", "", "   ", "line one\nline two"] {
            #expect(suggest(text) == .none, "\(text) should offer nothing")
        }
        #expect(suggest(String(repeating: "safari ", count: 20)) == .none)
    }

    @Test func aQuestionThatMentionsAnAppIsNotALaunch() {
        // The matcher needs the whole text to name the target, so sentences do not match.
        for text in ["why is safari slow", "is xcode free", "how do I use ghidra to open a file"] {
            #expect(suggest(text) == .none, "\(text) should offer nothing")
        }
    }

    @Test func lettersBuriedInsideANameAreNotASuggestion() {
        #expect(suggest("hi") == .none)          // inside "Ghidra"
        #expect(suggest("code") == .none || suggest("code").entries.allSatisfy { $0.name.lowercased().contains("code") })
        #expect(suggest("studio").entries.map(\.name) == ["Visual Studio Code"])  // starts a word: offered
        #expect(!suggest("studio").preselect)
    }

    @Test func atMostFourAreOffered() {
        let many = Registry(
            entries: (1...20).map { RegistryEntry(kind: .app, name: "Tool \($0)", url: URL(fileURLWithPath: "/Applications/Tool \($0).app")) },
            editor: vsCode
        )
        #expect(LaunchSuggestion.suggest(for: "tool", registry: many).entries.count == 4)
    }
}
