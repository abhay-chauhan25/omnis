import Foundation

/// Opening one of the user's saved apps or projects when Claude is asked to.
///
/// A plain "open Spotify" never reaches a model: it is matched and opened at
/// once. This is for the looser ways of asking, mostly by voice. Claude gives
/// a name and nothing else; what opens is whatever that name matches in the
/// user's own list, so nothing outside the list can be opened this way.
public final class AppsTools: AssistantTools, Sendable {
    public let service = "apps"
    public let toolNames: Set<String> = ["apps_open"]
    /// Opening something reads nothing of the user's.
    public let holdsPersonalData = false
    private let registry: @Sendable () -> Registry?
    private let performer: LaunchPerforming

    public init(registry: @escaping @Sendable () -> Registry?, performer: LaunchPerforming) {
        self.registry = registry
        self.performer = performer
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        guard tool == "apps_open" else { throw ToolRefusal("that is not something OMNIS can open") }
        // Like sending and deleting, never in a chat that holds a file: the file's text could be what asks.
        guard access.opens else { throw ToolRefusal("apps are not opened from a chat that holds a file. The user can ask in a new chat, or open it themselves") }
        let name = CalendarFormatter.clean(arguments["name"] ?? "")
        guard !name.isEmpty, name.count <= 80 else { throw ToolRefusal("say which app or project to open") }
        guard let all = registry() else { throw ToolRefusal("the list of apps and projects could not be read") }
        // Apps and projects only. A launcher runs a program of the user's, and only the user starts one.
        let listed = Registry(entries: all.entries.filter { $0.kind != .launcher }, aliases: all.aliases, editor: all.editor)
        let matches = Matcher.rank(query: name, registry: listed, limit: 5)
        let near = matches.map(\.entry.name).joined(separator: ", ")
        guard let top = matches.first, top.score > Matcher.substring else {
            throw ToolRefusal(matches.isEmpty ? "nothing called \"\(name)\" is among the user's apps and projects"
                              : "nothing has just that name. The closest are: \(near). Ask the user which they mean")
        }
        // Two that fit equally well: the user says which.
        if matches.count > 1, top.score - matches[1].score <= Matcher.maxLengthPenalty, top.score < Matcher.exact {
            throw ToolRefusal("more than one fits: \(near). Ask the user which they mean")
        }
        try await Executor(registry: listed, performer: performer).launch(entryID: top.entry.id)
        let what = top.entry.kind == .project ? "the project \(top.entry.name) in the editor" : top.entry.name
        return .done(content: "Opened \(what).", note: "Opened \(top.entry.name)")
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        throw ToolRefusal("nothing to confirm for opening an app")
    }
}
