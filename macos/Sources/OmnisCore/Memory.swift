import Foundation

/// One thing the user has asked OMNIS to remember.
public struct MemoryFact: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var text: String
    public var added: Date

    public init(id: UUID = UUID(), text: String, added: Date) {
        self.id = id
        self.text = text
        self.added = added
    }
}

public enum MemoryError: Error, Equatable, LocalizedError {
    case empty
    case full
    case looksSecret

    public var errorDescription: String? {
        switch self {
        case .empty: return "There was nothing to remember."
        case .full: return "OMNIS is already remembering \(MemoryStore.maxFacts) things. Remove one first, in Memory."
        case .looksSecret: return "That looks like a password, a code or a key, and OMNIS does not remember those."
        }
    }
}

/// What OMNIS remembers about the user between chats: a short list of
/// sentences, each one put there by the user or approved by them.
///
/// The list is kept in one file on this Mac. It is added to what Claude is
/// told at the start of a chat, so it is short on purpose.
public final class MemoryStore: @unchecked Sendable {
    public static let maxFacts = 50
    public static let maxFactCharacters = 240
    /// The most of the list that is passed to a model.
    public static let maxPromptCharacters = 4_000

    private let file: URL
    private let lock = NSLock()
    private var loaded: [MemoryFact]?
    private let now: @Sendable () -> Date

    public init(file: URL, now: @escaping @Sendable () -> Date = { Date() }) {
        self.file = file
        self.now = now
    }

    /// Call with the lock held.
    private func read() -> [MemoryFact] {
        if let loaded { return loaded }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        let facts = (try? Data(contentsOf: file)).flatMap { try? decoder.decode([MemoryFact].self, from: $0) } ?? []
        loaded = facts
        return facts
    }

    /// Call with the lock held.
    private func write(_ facts: [MemoryFact]) {
        loaded = facts
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        guard let data = try? encoder.encode(facts) else { return }
        let files = FileManager.default
        try? files.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
        // The folder may be older than this rule: it is closed to other users each time.
        try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.deletingLastPathComponent().path)
        try? data.write(to: file, options: .atomic)
        try? files.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    /// Everything remembered, oldest first.
    public func facts() -> [MemoryFact] {
        lock.withLock { read() }
    }

    /// One sentence, on one line, within the length limit.
    public static func tidy(_ text: String) -> String {
        let oneLine = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return String(oneLine.prefix(maxFactCharacters))
    }

    /// True for text that reads like a password, a sign-in code or a key.
    /// Such things belong in the Keychain, never in a list a model is shown.
    public static func looksSecret(_ text: String) -> Bool {
        let lowered = text.lowercased()
        let named = #"\b(password|passcode|passphrase|pin|pin code|verification code|security code|api key|secret key|token|ssn|social security number)\b"#
        if lowered.range(of: named, options: .regularExpression) != nil {
            // "…is hunter2", "password: x", or anything with a digit in it beside the word.
            if lowered.range(of: #"\b(is|are)\b|[:=]|\S*\d\S*"#, options: .regularExpression) != nil { return true }
            // "my password hunter": the word and then the thing itself. "Password manager" is talk about passwords, not one.
            if lowered.range(of: named.dropLast(2) + #"\s+(?!managers?\b)\S+\s*$"#, options: .regularExpression) != nil { return true }
        }
        // A card number, or a bank account number in the international form.
        if text.range(of: #"\b(?:\d[ -]?){13,19}\b"#, options: .regularExpression) != nil { return true }
        if text.range(of: #"\b[A-Z]{2}\d{2}(?: ?[A-Z0-9]){11,30}\b"#, options: .regularExpression) != nil { return true }
        // A long unbroken run of letters and digits mixed together, the shape of a key.
        return text.range(of: #"\b(?=[A-Za-z0-9_\-]*\d)(?=[A-Za-z0-9_\-]*[A-Za-z])[A-Za-z0-9_\-]{24,}\b"#, options: .regularExpression) != nil
    }

    /// Adds one thing to remember. The same sentence twice is kept once.
    @discardableResult
    public func add(_ text: String) throws -> MemoryFact {
        let tidy = Self.tidy(text)
        guard !tidy.isEmpty else { throw MemoryError.empty }
        guard !Self.looksSecret(tidy) else { throw MemoryError.looksSecret }
        return try lock.withLock {
            var facts = read()
            if let same = facts.first(where: { $0.text.caseInsensitiveCompare(tidy) == .orderedSame }) { return same }
            guard facts.count < Self.maxFacts else { throw MemoryError.full }
            let fact = MemoryFact(text: tidy, added: now())
            facts.append(fact)
            write(facts)
            return fact
        }
    }

    public func update(_ id: UUID, to text: String) throws {
        let tidy = Self.tidy(text)
        guard !tidy.isEmpty else { throw MemoryError.empty }
        guard !Self.looksSecret(tidy) else { throw MemoryError.looksSecret }
        lock.withLock {
            var facts = read()
            guard let index = facts.firstIndex(where: { $0.id == id }) else { return }
            facts[index].text = tidy
            write(facts)
        }
    }

    public func remove(_ id: UUID) {
        lock.withLock {
            let facts = read()
            guard facts.contains(where: { $0.id == id }) else { return }
            write(facts.filter { $0.id != id })
        }
    }

    public func removeAll() {
        lock.withLock { write([]) }
    }

    /// The list as lines for a model, newest kept if it is too long to pass whole.
    public func promptLines() -> [String] {
        var lines: [String] = []
        var characters = 0
        for fact in facts().reversed() {
            characters += fact.text.count
            if characters > Self.maxPromptCharacters { break }
            lines.insert(fact.text, at: 0)
        }
        return lines
    }

    /// The remembered thing that best matches a few words, for "forget that…".
    /// Nil unless one fact stands clear of the rest.
    public func match(_ words: String) -> MemoryFact? {
        let wanted = Set(Self.keywords(words))
        guard !wanted.isEmpty else { return nil }
        let scored = facts().map { fact in (fact, wanted.intersection(Self.keywords(fact.text)).count) }
            .filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }
        guard let best = scored.first else { return nil }
        if scored.count > 1, scored[1].1 == best.1 { return nil }
        return best.0
    }

    private static let small: Set<String> = ["the", "a", "an", "my", "i", "is", "are", "that", "to", "of", "and", "in", "on", "for",
                                             "user", "users", "their", "they", "about", "it", "me", "you", "your", "what", "forget"]

    static func keywords(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count > 1 && !small.contains($0) }
    }
}

/// Lets a model ask for something to be remembered or forgotten. It can only
/// ask: each request becomes a preview, and the list changes only when the
/// user clicks to confirm it.
public final class MemoryTools: AssistantTools, @unchecked Sendable {
    public let service = "memory"
    public let toolNames: Set<String> = ["memory_remember", "memory_forget"]
    /// What is remembered is the user's own and already goes to Claude; noting it does not make a chat private.
    public let holdsPersonalData = false
    private let store: MemoryStore
    private let changed: @Sendable () -> Void

    public init(store: MemoryStore, changed: @escaping @Sendable () -> Void = {}) {
        self.store = store
        self.changed = changed
    }

    public func run(tool: String, arguments: [String: String], access: ToolAccess) async throws -> ToolOutcome {
        // A file or an email in the chat could be what is asking, so nothing is remembered from such a chat.
        guard access.remembers else {
            throw ToolRefusal("nothing can be remembered or forgotten in a chat that holds a file or an email. "
                              + "Tell the user they can add it themselves in Memory, or ask in a new chat")
        }
        switch tool {
        case "memory_remember":
            let fact = MemoryStore.tidy(arguments["fact"] ?? "")
            guard !fact.isEmpty else { throw ToolRefusal("say what to remember, as one short sentence") }
            guard !MemoryStore.looksSecret(fact) else {
                throw ToolRefusal("that looks like a password, a code or a key. OMNIS does not remember those; say so")
            }
            if store.facts().contains(where: { $0.text.caseInsensitiveCompare(fact) == .orderedSame }) {
                return .done(content: "That is already remembered. Say so in a few words.", note: "Checked memory")
            }
            guard store.facts().count < MemoryStore.maxFacts else { throw ToolRefusal(MemoryError.full.localizedDescription) }
            return .proposal(ActionProposal(service: service, kind: "remember", heading: "Remember", title: fact,
                                            rows: [ChangeRow("Used", "in every chat from now on")],
                                            confirmLabel: "Remember", declineLabel: "Don't", payload: ["action": "remember", "fact": fact]))
        case "memory_forget":
            guard let fact = store.match(arguments["about"] ?? "") else {
                throw ToolRefusal("no single remembered thing matches that. Ask the user which one they mean, or tell them they can remove it in Memory")
            }
            return .proposal(ActionProposal(service: service, kind: "forget", heading: "Forget", title: fact.text,
                                            confirmLabel: "Forget", declineLabel: "Keep", destructive: true,
                                            payload: ["action": "forget", "id": fact.id.uuidString]))
        default:
            throw ToolRefusal("that is not something OMNIS can do")
        }
    }

    public func perform(_ proposal: ActionProposal) async throws -> String {
        switch proposal.payload["action"] {
        case "remember":
            try store.add(proposal.payload["fact"] ?? "")
            changed()
            return "Remembered"
        case "forget":
            guard let id = proposal.payload["id"].flatMap(UUID.init(uuidString:)) else { throw MemoryError.empty }
            store.remove(id)
            changed()
            return "Forgotten"
        default:
            throw MemoryError.empty
        }
    }
}
