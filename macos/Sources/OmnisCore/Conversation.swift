import Foundation

/// One earlier turn of a conversation, as sent to the model.
public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// One message shown in the chat window.
public struct ChatMessage: Equatable, Identifiable, Sendable {
    public enum Role: Sendable { case user, assistant }
    public enum State: Equatable, Sendable {
        case streaming
        case done
        /// The answer could not be produced. The text says why.
        case failed(String)
        /// Stopped by the user before it finished.
        case stopped
    }

    public let id: UUID
    public let role: Role
    public var text: String
    public var state: State
    /// True while a web search for this answer is running.
    public var searching = false
    /// What was searched for, as the model worded it.
    public var searchQueries: [String] = []
    /// The pages the model was given, numbered as it cites them.
    public var sources: [SearchResult] = []
    /// Why a web search could not be done, if one failed.
    public var searchProblem: String?
    /// The "which model answered" line.
    public var sourceLine: String?

    public init(id: UUID = UUID(), role: Role, text: String, state: State = .done) {
        self.id = id
        self.role = role
        self.text = text
        self.state = state
    }
}

/// The conversation in the chat window. It lives only in memory: it is gone
/// when a new chat is started or OMNIS quits.
public struct Conversation: Equatable, Sendable {
    public private(set) var messages: [ChatMessage] = []
    /// True once the user has kept any turn of this chat on this Mac. From
    /// then on the whole chat stays local, so a later question cannot carry
    /// those turns to Claude as history. A new chat clears it.
    public private(set) var staysLocal = false

    public init() {}

    public mutating func keepLocal() {
        staysLocal = true
    }

    public var isEmpty: Bool { messages.isEmpty }
    public var isAnswering: Bool { messages.last?.state == .streaming }

    /// Adds the user's message and an empty answer to fill in. Returns the answer's id.
    @discardableResult
    public mutating func begin(question: String) -> UUID {
        messages.append(ChatMessage(role: .user, text: question))
        let answer = ChatMessage(role: .assistant, text: "", state: .streaming)
        messages.append(answer)
        return answer.id
    }

    /// Changes one message in place. Does nothing if it is no longer there
    /// (for example after a new chat was started mid-answer).
    public mutating func update(_ id: UUID, _ change: (inout ChatMessage) -> Void) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        change(&messages[index])
    }

    public mutating func clear() {
        messages.removeAll()
        staysLocal = false
    }

    /// The most history sent with one question, matching what the backend accepts.
    public static let maxHistoryMessages = 24
    public static let maxHistoryCharacters = 12_000

    /// The earlier turns to send with the next question, oldest first.
    ///
    /// Only finished exchanges are included: a failed or empty answer, and the
    /// question that led to it, are left out so the model is not shown its
    /// own errors as if they were things it said. Only the most recent
    /// exchanges that fit the limits are kept, whole.
    public func history() -> [ChatTurn] {
        let all = allFinishedTurns()
        var kept: [ChatTurn] = []
        var characters = 0
        var index = all.count
        while index >= 2 {
            let question = all[index - 2], answer = all[index - 1]
            characters += question.content.count + answer.content.count
            if kept.count + 2 > Self.maxHistoryMessages || characters > Self.maxHistoryCharacters { break }
            kept.insert(contentsOf: [question, answer], at: 0)
            index -= 2
        }
        return kept
    }

    private func allFinishedTurns() -> [ChatTurn] {
        var turns: [ChatTurn] = []
        var index = 0
        while index + 1 < messages.count {
            let question = messages[index]
            let answer = messages[index + 1]
            if question.role == .user, answer.role == .assistant {
                let usable = (answer.state == .done || answer.state == .stopped)
                    && !answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                if usable {
                    turns.append(ChatTurn(role: .user, content: question.text))
                    turns.append(ChatTurn(role: .assistant, content: answer.text))
                }
                index += 2
            } else {
                index += 1
            }
        }
        return turns
    }
}

// MARK: - Block formatting

/// A piece of an answer, for display: models write Markdown with headings,
/// lists and code blocks, and showing those as typed is hard to read.
public enum AnswerBlock: Equatable, Sendable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case bullet(String)
    case numbered(number: String, text: String)
    case code(String)
}

public enum AnswerBlocks {
    public static func parse(_ text: String) -> [AnswerBlock] {
        var blocks: [AnswerBlock] = []
        var paragraph: [String] = []
        var code: [String]?

        func flushParagraph() {
            if !paragraph.isEmpty {
                blocks.append(.paragraph(paragraph.joined(separator: "\n")))
                paragraph.removeAll()
            }
        }

        for rawLine in text.components(separatedBy: "\n") {
            let line = rawLine.trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if trimmed.hasPrefix("```") {
                if let lines = code {
                    blocks.append(.code(lines.joined(separator: "\n")))
                    code = nil
                } else {
                    flushParagraph()
                    code = []
                }
                continue
            }
            if code != nil {
                code?.append(line)
                continue
            }

            if trimmed.isEmpty {
                flushParagraph()
            } else if let heading = heading(trimmed) {
                flushParagraph()
                blocks.append(heading)
            } else if let item = bullet(trimmed) {
                flushParagraph()
                blocks.append(.bullet(item))
            } else if let item = numbered(trimmed) {
                flushParagraph()
                blocks.append(.numbered(number: item.number, text: item.text))
            } else {
                paragraph.append(trimmed)
            }
        }
        // An answer still being written may end inside a code block.
        if let lines = code { blocks.append(.code(lines.joined(separator: "\n"))) }
        flushParagraph()
        return blocks
    }

    private static func heading(_ line: String) -> AnswerBlock? {
        let hashes = line.prefix(while: { $0 == "#" }).count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        let text = line.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : .heading(level: hashes, text: text)
    }

    private static func bullet(_ line: String) -> String? {
        guard let first = line.first, "-*•".contains(first), line.dropFirst().first == " " else { return nil }
        let text = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    private static func numbered(_ line: String) -> (number: String, text: String)? {
        let digits = line.prefix(while: { $0.isNumber })
        guard (1...3).contains(digits.count) else { return nil }
        let rest = line.dropFirst(digits.count)
        guard let mark = rest.first, mark == "." || mark == ")", rest.dropFirst().first == " " else { return nil }
        let text = rest.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : (String(digits), text)
    }
}
