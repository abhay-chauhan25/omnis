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

/// A typed prefix that picks the route by hand: "local: ..." or "claude: ...".
public enum RoutePrefix {
    public static func split(_ text: String) -> (route: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for route in ["local", "claude"] {
            let prefix = route + ":"
            if trimmed.lowercased().hasPrefix(prefix) {
                let rest = trimmed.dropFirst(prefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
                if !rest.isEmpty { return (route, rest) }
            }
        }
        return ("auto", trimmed)
    }
}
