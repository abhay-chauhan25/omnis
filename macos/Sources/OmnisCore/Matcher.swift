import Foundation

public enum TextNormalizer {
    /// Lowercases, turns anything that is not a letter or digit into a space,
    /// and collapses runs of spaces. "ChatGPT  Classic!" -> "chatgpt classic".
    public static func normalize(_ text: String) -> String {
        var out = ""
        var pendingSpace = false
        for scalar in text.lowercased().unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                if pendingSpace && !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.unicodeScalars.append(scalar)
            } else {
                pendingSpace = true
            }
        }
        return out
    }

    public static func compact(_ normalized: String) -> String {
        normalized.replacingOccurrences(of: " ", with: "")
    }
}

/// What is left of a typed command once filler words are removed.
public struct ParsedQuery: Equatable, Sendable {
    /// The words that name the target, normalised.
    public let core: String
    /// A kind the wording points at ("... app", "... project", "... in VS Code").
    public let hintedKind: EntryKind?
}

public enum QueryParser {
    static let verbs: Set<String> = ["open", "launch", "start", "run"]
    static let articles: Set<String> = ["the", "my"]
    /// Words people put around a request that say nothing about the target.
    static let politeLead: Set<String> = ["please", "can", "could", "would", "will", "you", "hey", "omnis", "just", "okay", "ok", "i", "want",
                                          "need", "to", "wanna", "like", "lets", "let", "us", "go", "ahead", "and", "now", "quickly"]
    static let politeTail: Set<String> = ["please", "now", "thanks", "quickly", "again"]
    /// Said after the name, mostly aloud: "open Spotify for me", "open Notes real quick".
    static let tailPhrases: [[String]] = [["for", "me"], ["for", "me", "please"], ["real", "quick"], ["right", "now"], ["thank", "you"], ["if", "you", "can"],
                                          ["would", "you"], ["will", "you"], ["can", "you"]]
    static let appWords: Set<String> = ["app", "application"]
    static let projectWords: Set<String> = ["project", "repo", "folder"]
    static let editorPhrases: [[String]] = [
        ["visual", "studio", "code"], ["vs", "code"], ["vscode"], ["code"],
    ]
    static let editorPrepositions: Set<String> = ["in", "with", "using"]

    public static func parse(_ raw: String) -> ParsedQuery {
        var tokens = TextNormalizer.normalize(raw).split(separator: " ").map(String.init)
        var hint: EntryKind?

        // "... in vs code" at the end means a project. Only strip it when a
        // target name remains in front of it.
        for phrase in editorPhrases {
            let tailLength = phrase.count + 1
            guard tokens.count > tailLength else { continue }
            let tail = Array(tokens.suffix(tailLength))
            if editorPrepositions.contains(tail[0]) && Array(tail.dropFirst()) == phrase {
                tokens.removeLast(tailLength)
                hint = .project
                break
            }
        }

        // "can you open safari", "open safari please", "open up safari".
        if let verbAt = tokens.firstIndex(where: { verbs.contains($0) }), verbAt > 0, verbAt < tokens.count - 1,
           tokens[..<verbAt].allSatisfy({ politeLead.contains($0) }) {
            tokens.removeFirst(verbAt)
        }
        var trimmed = true
        while trimmed {
            trimmed = false
            for phrase in tailPhrases where tokens.count > phrase.count + 1 && Array(tokens.suffix(phrase.count)) == phrase {
                tokens.removeLast(phrase.count)
                trimmed = true
            }
            while tokens.count > 2, let last = tokens.last, politeTail.contains(last) {
                tokens.removeLast()
                trimmed = true
            }
        }
        if tokens.count > 1, let first = tokens.first, verbs.contains(first) {
            tokens.removeFirst()
            if tokens.count > 1, tokens.first == "up" { tokens.removeFirst() }
        }
        if tokens.count > 1, let first = tokens.first, articles.contains(first) {
            tokens.removeFirst()
        }
        if tokens.count > 1, let last = tokens.last {
            if appWords.contains(last) {
                tokens.removeLast()
                hint = hint ?? .app
            } else if projectWords.contains(last) {
                tokens.removeLast()
                hint = .project
            }
        }
        return ParsedQuery(core: tokens.joined(separator: " "), hintedKind: hint)
    }
}

public struct Match: Equatable, Sendable {
    public let entry: RegistryEntry
    public let score: Int
}

/// Rule-based ranking. No model is involved, so it is fast enough to run on
/// every keystroke and always gives the same answer for the same input.
public enum Matcher {
    static let aliasExact = 1000
    static let exact = 900
    static let aliasPrefix = 750
    static let prefix = 700
    static let wordPrefix = 500
    static let substring = 300
    static let maxLengthPenalty = 40

    public static func rank(query raw: String, registry: Registry, limit: Int = 6) -> [Match] {
        let parsed = QueryParser.parse(raw)
        let core = parsed.core
        guard !core.isEmpty else { return [] }
        let coreCompact = TextNormalizer.compact(core)
        let coreTokens = core.split(separator: " ").map(String.init)

        var aliasScores: [String: Int] = [:]
        for (phrase, target) in registry.aliases {
            let score: Int
            if phrase == core {
                score = aliasExact
            } else if phrase.hasPrefix(core) {
                score = aliasPrefix
            } else {
                continue
            }
            aliasScores[target] = max(aliasScores[target] ?? 0, score)
        }

        var matches: [Match] = []
        for entry in registry.entries {
            let name = TextNormalizer.normalize(entry.name)
            var best = nameScore(core: core, coreCompact: coreCompact, coreTokens: coreTokens, name: name)
            if let alias = aliasScores[entry.id] {
                best = max(best ?? 0, alias)
            }
            guard let score = best else { continue }
            matches.append(Match(entry: entry, score: score))
        }

        // If the wording names a kind ("... app", "... in VS Code"), entries of
        // that kind come first; the others stay listed below them.
        let hint = parsed.hintedKind
        matches.sort { a, b in
            if let hint, (a.entry.kind == hint) != (b.entry.kind == hint) { return a.entry.kind == hint }
            if a.score != b.score { return a.score > b.score }
            return a.entry.name.localizedCaseInsensitiveCompare(b.entry.name) == .orderedAscending
        }
        return Array(matches.prefix(limit))
    }

    static func nameScore(core: String, coreCompact: String, coreTokens: [String], name: String) -> Int? {
        guard !name.isEmpty else { return nil }
        let nameCompact = TextNormalizer.compact(name)
        if name == core || nameCompact == coreCompact { return exact }

        // Closer names rank higher: "voy" prefers "Voyagers" over a much longer name.
        let penalty = min(max(nameCompact.count - coreCompact.count, 0), maxLengthPenalty)

        if name.hasPrefix(core) || nameCompact.hasPrefix(coreCompact) { return prefix - penalty }

        let words = name.split(separator: " ")
        if coreTokens.allSatisfy({ token in words.contains { $0.hasPrefix(token) } }) {
            return wordPrefix - penalty
        }
        if coreCompact.count >= 2 && nameCompact.contains(coreCompact) {
            return substring - penalty
        }
        return nil
    }
}


/// What to offer in the chat window's launch strip for the text typed so far.
public struct LaunchSuggestion: Equatable, Sendable {
    public let entries: [RegistryEntry]
    /// True when Enter should launch the first entry instead of sending the
    /// text as a message. In a chat box most text is a message, so this is
    /// only true when the wording clearly asks for a launch: it starts with a
    /// verb such as "open", or it is an entry's full name or an alias.
    public let preselect: Bool

    public static let none = LaunchSuggestion(entries: [], preselect: false)

    /// What a spoken request should open at once, if anything. Stricter than
    /// typing, because nobody is looking at a list of suggestions: the words
    /// must ask for it ("open ..."), one entry must fit better than any other,
    /// and a launcher, which runs a program, is never started by voice alone.
    public static func spoken(_ said: String, registry: Registry) -> RegistryEntry? {
        let trimmed = said.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80 else { return nil }
        let words = TextNormalizer.normalize(trimmed).split(separator: " ").map(String.init)
        guard let verbAt = words.firstIndex(where: { QueryParser.verbs.contains($0) }), verbAt < words.count - 1,
              words[..<verbAt].allSatisfy({ QueryParser.politeLead.contains($0) }) else { return nil }
        let listed = Registry(entries: registry.entries.filter { $0.kind != .launcher }, aliases: registry.aliases, editor: registry.editor)
        let matches = Matcher.rank(query: trimmed, registry: listed, limit: 3).filter { $0.score > Matcher.substring }
        guard let top = matches.first else { return nil }
        // Two that fit about as well ("voy" for VoyagerAI and Voyagers): not guessed between.
        if matches.count > 1, top.score - matches[1].score <= Matcher.maxLengthPenalty, top.score < Matcher.exact { return nil }
        return top.entry
    }

    public static func suggest(for input: String, registry: Registry, limit: Int = 4) -> LaunchSuggestion {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\n"), trimmed.count <= 80 else { return .none }
        // In a chat box, text that merely appears somewhere inside a name
        // ("hi" in "Ghidra") is far more likely a message than a launch, so
        // only names that the text starts, or starts a word of, are offered.
        let matches = Matcher.rank(query: trimmed, registry: registry, limit: 12)
            .filter { $0.score > Matcher.substring }
            .prefix(limit)
        guard let top = matches.first else { return .none }
        let tokens = TextNormalizer.normalize(trimmed).split(separator: " ")
        let words = tokens.map(String.init)
        let verbAt = words.firstIndex(where: { QueryParser.verbs.contains($0) })
        let startsWithVerb = verbAt.map { index in
            index < words.count - 1 && words[..<index].allSatisfy { QueryParser.politeLead.contains($0) }
        } ?? false
        return LaunchSuggestion(
            entries: matches.map(\.entry),
            preselect: startsWithVerb || top.score >= Matcher.exact
        )
    }
}
