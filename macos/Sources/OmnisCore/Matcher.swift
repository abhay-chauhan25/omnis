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

        if tokens.count > 1, let first = tokens.first, verbs.contains(first) {
            tokens.removeFirst()
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
