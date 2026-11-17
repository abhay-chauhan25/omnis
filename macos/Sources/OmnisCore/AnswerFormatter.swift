import Foundation

/// Turns model output into text for display.
///
/// Models write light Markdown (bold, italics, inline code), and that
/// formatting is kept. Links are not: a link written by a model would be a
/// clickable action chosen by untrusted text, so every link is reduced to
/// plain, unclickable words.
public enum AnswerFormatter {
    public static func format(_ text: String) -> AttributedString {
        guard !text.isEmpty else { return AttributedString(" ") }
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        guard var formatted = try? AttributedString(markdown: text, options: options) else {
            return AttributedString(text)
        }
        for run in formatted.runs where run.link != nil {
            formatted[run.range].link = nil
        }
        return formatted
    }
}

/// How one question should be handled, from an optional typed prefix:
///   "local: ..."    stay on this Mac's models, whatever the wording
///   "claude: ..."   send to Claude
///   "offline: ..."  stay on this Mac and do not search the web
public struct AskOptions: Equatable, Sendable {
    public var route: String
    public var web: Bool
    public var text: String

    public init(route: String = "auto", web: Bool = true, text: String) {
        self.route = route
        self.web = web
        self.text = text
    }
}

public enum RoutePrefix {
    private static let prefixes: [(word: String, route: String, web: Bool)] = [
        ("local", "local", true),
        ("claude", "claude", true),
        ("offline", "local", false),
    ]

    public static func split(_ text: String) -> AskOptions {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for entry in prefixes {
            let prefix = entry.word + ":"
            if trimmed.lowercased().hasPrefix(prefix) {
                let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return AskOptions(route: entry.route, web: entry.web, text: rest) }
            }
        }
        return AskOptions(text: trimmed)
    }
}
