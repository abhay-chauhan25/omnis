import Foundation

/// One earlier turn of a conversation, as sent to the model.
public struct ChatTurn: Equatable, Sendable {
    public enum Role: String, Sendable { case user, assistant }
    public let role: Role
    public let content: String
    /// Files that went with a user turn.
    public let attachments: [Attachment]

    public init(role: Role, content: String, attachments: [Attachment] = []) {
        self.role = role
        self.content = content
        self.attachments = attachments
    }
}

/// A change to the calendar shown to the user for confirmation.
public struct EventProposal: Equatable, Identifiable, Sendable {
    public enum State: Equatable, Sendable {
        /// Shown, and waiting for the user to add it or not.
        case waiting
        case saving
        /// Carried out. The text says what was done, such as "Added to Home".
        case done(String)
        /// The user chose not to do it.
        case declined
        /// A later answer proposed something else before this was confirmed.
        case replaced
        case failed(String)
    }

    public let id: UUID
    public let change: CalendarChange
    public var state: State
    /// For a new event with no calendar named: the default one, once known.
    public var calendarName: String?

    public init(id: UUID = UUID(), change: CalendarChange, state: State = .waiting, calendarName: String? = nil) {
        self.id = id
        self.change = change
        self.state = state
        self.calendarName = calendarName
    }

    public init(id: UUID = UUID(), draft: EventDraft, state: State = .waiting, calendarName: String? = nil) {
        self.init(id: id, change: .create(draft), state: state, calendarName: calendarName)
    }
}

/// A new project shown to the user for confirmation.
public struct ProjectProposal: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let plan: ProjectPlan
    public var state: EventProposal.State
    /// The step being carried out, while it is being set up.
    public var progress: String?

    public init(id: UUID = UUID(), plan: ProjectPlan, state: EventProposal.State = .waiting) {
        self.id = id
        self.plan = plan
        self.state = state
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
    /// The question "may this chat search the web?", if it came up in this answer.
    public var searchAsk: SearchAsk?
    /// True while the calendar is being read for this answer.
    public var readingCalendar = false
    /// What was read from the calendar, in a few words ("18 Nov, 2 events").
    public var calendarNotes: [String] = []
    /// Why the calendar could not be read, if a read failed.
    public var calendarProblem: String?
    /// True when Claude could not be used for this answer and the local
    /// model is offered instead.
    public var offersLocal = false
    /// New events proposed in this answer, each waiting for the user's decision.
    public var proposals: [EventProposal] = []
    /// Changes proposed by other services in this answer (a reminder, a message).
    public var actions: [ActionProposal] = []
    /// Services read or used for this answer, in a few words each.
    public var serviceNotes: [String] = []
    /// New projects proposed in this answer, each waiting for the user's decision.
    public var projects: [ProjectProposal] = []
    /// Why an event could not be prepared, if one failed.
    public var proposalProblem: String?
    /// The "which model answered" line.
    public var sourceLine: String?
    /// Files the user attached to this message.
    public var attachments: [Attachment] = []

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
    /// True once a file has been attached in this chat. From then on nothing
    /// in the chat is used for a web search, even after the file itself has
    /// dropped out of the history that is sent along: the model's answers
    /// about the file are still there. A new chat clears it.
    public private(set) var hasPersonalData = false
    /// What the user has said about searching outside once this chat holds
    /// personal information. Asked once; a new chat clears it.
    public private(set) var searchConsent: SearchConsent = .notAsked

    public init() {}

    /// Records the user's answer to "may this chat search the web?" and
    /// settles any card still asking it.
    public mutating func settleSearch(allowed: Bool) {
        searchConsent = allowed ? .allowed : .refused
        for index in messages.indices where messages[index].searchAsk?.state == .waiting {
            messages[index].searchAsk?.state = allowed ? .allowed : .declined
        }
    }

    /// A question nobody answered: the card stops asking and nothing is decided.
    public mutating func lapseSearchAsk() {
        for index in messages.indices where messages[index].searchAsk?.state == .waiting {
            messages[index].searchAsk?.state = .lapsed
        }
    }

    public mutating func keepLocal() {
        staysLocal = true
    }

    /// Called when personal information enters the chat without a file being
    /// attached, such as when the calendar is read.
    public mutating func markPersonal() {
        hasPersonalData = true
        staysLocal = true
        calendarTouched = true
    }

    public var isEmpty: Bool { messages.isEmpty }
    public var isAnswering: Bool { messages.last?.state == .streaming }

    /// Adds the user's message and an empty answer to fill in. Returns the answer's id.
    @discardableResult
    public mutating func begin(question: String, attachments: [Attachment] = []) -> UUID {
        var message = ChatMessage(role: .user, text: question)
        message.attachments = attachments
        if !attachments.isEmpty {
            hasFile = true
            hasPersonalData = true
            staysLocal = true
        }
        messages.append(message)
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

    /// Adds a proposed event to an answer. Proposals still waiting under
    /// earlier answers are withdrawn: the new one is taken to replace them,
    /// so "make it 2pm instead" cannot leave two live previews.
    ///
    /// Within one answer, the same event twice is shown once, and there is a
    /// limit on how many previews one answer can carry.
    public mutating func add(_ proposal: EventProposal, to answerID: UUID) {
        guard let target = messages.firstIndex(where: { $0.id == answerID }) else { return }
        guard messages[target].proposals.count < Self.maxProposalsPerAnswer,
              !messages[target].proposals.contains(where: { $0.change == proposal.change }) else { return }
        offerEventsNext = true
        calendarTouched = true
        for index in messages.indices where index != target {
            for position in messages[index].proposals.indices where messages[index].proposals[position].state == .waiting {
                messages[index].proposals[position].state = .replaced
            }
        }
        messages[target].proposals.append(proposal)
    }

    public static let maxProposalsPerAnswer = 5

    // MARK: Changes from other services

    private var serviceDeleteNext = false

    /// What the other services may do for this message. Deleting needs the
    /// user's own words to say delete, cancel or remove (or to answer a
    /// question straight after saying so), whatever is being deleted, and is
    /// never allowed in a chat that holds a file.
    public mutating func serviceAccess(for text: String) -> ToolAccess {
        let asks = PersonalIntent.asksToDelete(text)
        let deletes = !hasFile && (asks || serviceDeleteNext)
        serviceDeleteNext = asks && !hasFile
        return ToolAccess(deletes: deletes, sends: false)
    }

    /// Adds a proposed change to an answer. The same change twice is shown once.
    public mutating func add(_ action: ActionProposal, to answerID: UUID) {
        guard let target = messages.firstIndex(where: { $0.id == answerID }),
              messages[target].actions.count < Self.maxProposalsPerAnswer,
              !messages[target].actions.contains(where: { $0.payload == action.payload && $0.kind == action.kind }) else { return }
        messages[target].actions.append(action)
    }

    public func action(_ id: UUID) -> ActionProposal? {
        messages.lazy.flatMap(\.actions).first { $0.id == id }
    }

    public mutating func updateAction(_ id: UUID, _ change: (inout ActionProposal) -> Void) {
        for index in messages.indices {
            if let position = messages[index].actions.firstIndex(where: { $0.id == id }) {
                change(&messages[index].actions[position])
                return
            }
        }
    }

    /// The user clicked to confirm. Returns the change and marks it as under
    /// way, or nil if it may not run: only one that is waiting, or that failed, can.
    public mutating func beginAction(_ id: UUID) -> ActionProposal? {
        guard let found = action(id) else { return nil }
        switch found.state {
        case .waiting, .failed:
            updateAction(id) { $0.state = .saving }
            return found
        case .saving, .done, .declined, .replaced:
            return nil
        }
    }

    public mutating func declineAction(_ id: UUID) -> Bool {
        guard let state = action(id)?.state else { return false }
        if case .failed = state {} else if state != .waiting { return false }
        updateAction(id) { $0.state = .declined }
        return true
    }

    static func actionNotes(_ actions: [ActionProposal]) -> String {
        actions.map { action in
            let outcome: String
            switch action.state {
            case .waiting: outcome = "preview shown, not yet confirmed by the user, NOT done"
            case .saving: outcome = "the user confirmed it and it is being done now"
            case .done: outcome = "the user confirmed it and it was done"
            case .declined: outcome = "the user chose not to do it"
            case .replaced: outcome = "replaced by a later preview, not done"
            case .failed: outcome = "it could not be done"
            }
            return "\n[Preview: \(action.line). Status: \(outcome).]"
        }.joined()
    }

    // MARK: New projects

    private var offerProjectNext = false

    /// Whether the model may prepare a new project for this message: only
    /// when the user's own words ask for one, or answer a question about one
    /// (such as "public or private?") straight after.
    public mutating func offersProject(for text: String) -> Bool {
        let asks = ProjectIntent.asksToCreate(text)
        let offered = asks || offerProjectNext
        offerProjectNext = asks
        return offered
    }

    /// Adds a proposed project to an answer. One per answer, and a newer one
    /// withdraws any still waiting elsewhere.
    public mutating func add(_ proposal: ProjectProposal, to answerID: UUID) {
        guard let target = messages.firstIndex(where: { $0.id == answerID }), messages[target].projects.isEmpty else { return }
        for index in messages.indices where index != target {
            for position in messages[index].projects.indices where messages[index].projects[position].state == .waiting {
                messages[index].projects[position].state = .replaced
            }
        }
        messages[target].projects.append(proposal)
        offerProjectNext = true
    }

    public func project(_ id: UUID) -> ProjectProposal? {
        messages.lazy.flatMap(\.projects).first { $0.id == id }
    }

    public mutating func updateProject(_ id: UUID, _ change: (inout ProjectProposal) -> Void) {
        for index in messages.indices {
            if let position = messages[index].projects.firstIndex(where: { $0.id == id }) {
                change(&messages[index].projects[position])
                return
            }
        }
    }

    /// The user clicked to set a project up. Returns the plan and marks it as
    /// under way, or nil if it may not be run: only a waiting preview can be.
    /// Unlike a calendar change, a failed set-up is not retried, because part
    /// of it may already exist.
    public mutating func beginProject(_ id: UUID) -> ProjectPlan? {
        guard let found = project(id), found.state == .waiting else { return nil }
        updateProject(id) { $0.state = .saving }
        return found.plan
    }

    public mutating func declineProject(_ id: UUID) -> Bool {
        guard project(id)?.state == .waiting else { return false }
        updateProject(id) { $0.state = .declined }
        return true
    }

    static func projectNotes(_ projects: [ProjectProposal]) -> String {
        projects.map { proposal in
            let outcome: String
            switch proposal.state {
            case .waiting: outcome = "preview shown, not yet confirmed by the user, NOT created"
            case .saving: outcome = "the user confirmed it and it is being set up now"
            case .done: outcome = "the user confirmed it and it was set up"
            case .declined: outcome = "the user chose not to create it"
            case .replaced: outcome = "replaced by a later preview, not created"
            case .failed(let why): outcome = "setting it up failed: \(why)"
            }
            return "\n[Project preview: \(proposal.plan.line). Status: \(outcome).]"
        }.joined()
    }

    /// True when the last exchange was about adding an event, so a follow-up
    /// such as "make it 2pm" or "tomorrow at 3" may still prepare one.
    private var offerEventsNext = false
    /// True once the calendar has been read or a change prepared in this
    /// chat. After that, "delete the second one" is enough to ask for a change.
    private var calendarTouched = false
    private var deleteNext = false
    /// True once a file has been attached in this chat.
    private var hasFile = false

    /// Whether the model may prepare an event for this message. Only when the
    /// user's own words ask for one, or follow straight on from asking, and
    /// never on a message that carries a file.
    public mutating func offersEvents(for text: String, hasAttachments: Bool) -> Bool {
        offer(for: text, hasAttachments: hasAttachments).changes
    }

    /// What the model may prepare for this message.
    ///
    /// Deleting is held to a stricter rule than other changes. An event may
    /// be deleted only when the user's own message says delete, cancel or
    /// remove (or answers the model's question straight after such a
    /// message). A whole calendar only when the message itself says to delete
    /// a calendar. And nothing is deleted in a chat that holds a file, since
    /// text in the file could be steering the model.
    public mutating func offer(for text: String, hasAttachments: Bool) -> ChangeOffer {
        let asks = PersonalIntent.asksToChangeCalendar(text) || (calendarTouched && PersonalIntent.hasChangeVerb(text))
        let changes = !hasAttachments && (asks || offerEventsNext)
        var deletes = DeleteLevel.none
        let asksDelete = PersonalIntent.asksToDelete(text)
        if changes && !hasFile {
            if asksDelete {
                deletes = PersonalIntent.asksToDeleteCalendar(text) ? .all : .events
            } else if deleteNext {
                deletes = .events
            }
        }
        offerEventsNext = asks && !hasAttachments
        deleteNext = asksDelete && deletes != .none
        return ChangeOffer(changes: changes, deletes: deletes)
    }

    /// The user clicked to add a preview. Returns the event to save and marks
    /// it as being saved, or returns nil if it may not be saved: already
    /// saved or being saved, declined, replaced, or gone. A failed save may
    /// be tried again.
    public mutating func beginSaving(_ id: UUID) -> CalendarChange? {
        guard let found = proposal(id) else { return nil }
        switch found.state {
        case .waiting, .failed:
            updateProposal(id) { $0.state = .saving }
            return found.change
        case .saving, .done, .declined, .replaced:
            return nil
        }
    }

    /// The user chose not to add a preview. True if that changed anything.
    public mutating func declineProposal(_ id: UUID) -> Bool {
        guard let state = proposal(id)?.state, state == .waiting || { if case .failed = state { return true } else { return false } }() else { return false }
        updateProposal(id) { $0.state = .declined }
        return true
    }

    public func proposal(_ id: UUID) -> EventProposal? {
        messages.lazy.flatMap(\.proposals).first { $0.id == id }
    }

    /// Changes one proposal in place. Does nothing if it is no longer there.
    public mutating func updateProposal(_ id: UUID, _ change: (inout EventProposal) -> Void) {
        for index in messages.indices {
            if let position = messages[index].proposals.firstIndex(where: { $0.id == id }) {
                change(&messages[index].proposals[position])
                return
            }
        }
    }

    /// What became of the proposals in an answer, for the model to read in
    /// later turns, so it knows what was and was not added.
    static func proposalNotes(_ proposals: [EventProposal]) -> String {
        proposals.map { proposal in
            let outcome: String
            switch proposal.state {
            case .waiting: outcome = "preview shown, not yet confirmed by the user, NOT done"
            case .saving: outcome = "the user confirmed it and it is being done now"
            case .done: outcome = "the user confirmed it and it was done"
            case .declined: outcome = "the user chose not to do it"
            case .replaced: outcome = "replaced by a later preview, not done"
            case .failed: outcome = "it could not be done"
            }
            return "\n[Calendar preview: \(proposal.change.line()). Status: \(outcome).]"
        }.joined()
    }

    public mutating func clear() {
        messages.removeAll()
        staysLocal = false
        hasPersonalData = false
        searchConsent = .notAsked
        offerEventsNext = false
        calendarTouched = false
        deleteNext = false
        hasFile = false
        offerProjectNext = false
        serviceDeleteNext = false
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
        // Files are large, so only the most recent ones travel with later
        // questions. That is enough for "and what about the second chart?".
        if let latest = kept.lastIndex(where: { !$0.attachments.isEmpty }) {
            for position in kept.indices where position != latest && !kept[position].attachments.isEmpty {
                kept[position] = ChatTurn(role: kept[position].role, content: kept[position].content)
            }
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
                    && (!answer.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !answer.proposals.isEmpty
                        || !answer.projects.isEmpty || !answer.actions.isEmpty)
                if usable {
                    turns.append(ChatTurn(role: .user, content: question.text, attachments: question.attachments))
                    turns.append(ChatTurn(role: .assistant, content: answer.text + Self.proposalNotes(answer.proposals)
                                          + Self.projectNotes(answer.projects) + Self.actionNotes(answer.actions)))
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
