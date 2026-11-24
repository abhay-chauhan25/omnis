import Combine
import Foundation
import OmnisCore

/// Voice: "Hey OMNIS", a spoken conversation, and "that's all".
///
/// This ties the listening and speaking (`VoiceEngine`) to the rules of the
/// conversation (`VoiceFlow`) and to the chat. A spoken message is answered
/// exactly as a typed one is, with the same previews and the same limits.
@MainActor
final class VoiceModel: ObservableObject {
    /// The switch. While it is off the microphone is not used at all.
    @Published var isOn = false {
        didSet { if isOn != oldValue { switched() } }
    }
    @Published private(set) var state: VoiceFlow.State = .off
    /// How loud the room or the voice is right now, for the picture on screen.
    @Published private(set) var level = 0.0
    /// What is being heard, while in a conversation.
    @Published private(set) var hearing = ""
    @Published private(set) var problem: String?
    @Published var persona: VoicePersona {
        didSet { if let data = try? JSONEncoder().encode(persona) { UserDefaults.standard.set(data, forKey: Self.personaKey) } }
    }
    @Published private(set) var voiceName = VoiceEngine.voiceDescription()

    private let chat: ChatModel
    private let audit: AuditLog
    private let engine = VoiceEngine()
    private var flow = VoiceFlow()
    private var watching: AnyCancellable?
    private var replyTimer: Task<Void, Never>?
    /// The answer being waited for, and whether its search question has been asked aloud.
    private var awaited: UUID?
    private var askedSearch = false
    private var pendingAction: UUID?
    private var pendingEvent: UUID?
    private static let personaKey = "OMNISVoicePersona"
    private static let switchKey = "OMNISVoiceOn"

    var isActive: Bool { state != .off }
    /// True from the wake phrase until the conversation ends.
    var inConversation: Bool { state != .off && state != .waiting }

    var stateLine: String {
        switch state {
        case .off: return "Voice is off"
        case .waiting: return "Say \u{201C}Hey OMNIS\u{201D}"
        case .listening, .followUp, .confirming: return hearing.isEmpty ? "Listening" : hearing
        case .thinking: return "Thinking"
        case .speaking: return "Speaking"
        }
    }

    /// Brings the chat window forward when something in it needs the user's eyes or a click.
    private let showChat: () -> Void

    init(chat: ChatModel, audit: AuditLog, showChat: @escaping () -> Void = {}) {
        self.chat = chat
        self.showChat = showChat
        self.audit = audit
        if let data = UserDefaults.standard.data(forKey: Self.personaKey), let saved = try? JSONDecoder().decode(VoicePersona.self, from: data) {
            persona = saved
        } else {
            persona = VoicePersona()
        }
        engine.onUtterance = { [weak self] words in self?.heard(words) }
        engine.onPartial = { [weak self] words in
            guard let self, self.inConversation else { return }
            self.hearing = String(words.suffix(120))
            // Someone is speaking: do not give up on them mid-sentence.
            self.replyTimer?.cancel()
        }
        engine.onLevel = { [weak self] level in
            guard let self else { return }
            // Smoothed, so the picture swells and settles rather than flickers.
            self.level = self.level * 0.6 + level * 0.4
        }
        engine.onSpeechFinished = { [weak self] in
            guard let self else { return }
            self.run(self.flow.finishedSpeaking())
        }
        engine.onProblem = { [weak self] why in
            self?.problem = why
            self?.isOn = false
        }
        watching = chat.$conversation.sink { [weak self] conversation in
            // After this change has been stored.
            Task { @MainActor in self?.chatChanged(conversation) }
        }
        // The switch is remembered, so voice comes back on with OMNIS if it was left on.
        if UserDefaults.standard.bool(forKey: Self.switchKey) { isOn = true }
    }

    private func switched() {
        UserDefaults.standard.set(isOn, forKey: Self.switchKey)
        audit.record(action: "voice", outcome: isOn ? "on" : "off")
        if isOn {
            problem = nil
            voiceName = VoiceEngine.voiceDescription()
            Task {
                do {
                    try await engine.start()
                    run(flow.switchOn())
                } catch {
                    problem = error.localizedDescription
                    isOn = false
                }
            }
        } else {
            replyTimer?.cancel()
            run(flow.switchOff())
            engine.stop()
            state = .off
            level = 0
            hearing = ""
        }
    }

    /// Stops listening as OMNIS quits, without forgetting that the switch was on.
    func stopForQuit() {
        replyTimer?.cancel()
        engine.stop()
    }

    /// Cuts short what is being read aloud.
    func interrupt() {
        run(flow.interrupt())
    }

    private func heard(_ words: String) {
        replyTimer?.cancel()
        hearing = ""
        // A typed question is being answered: voice waits its turn.
        if flow.state == .waiting, chat.isAnswering { return }
        run(flow.heard(words))
    }

    private func run(_ effects: [VoiceFlow.Effect]) {
        for effect in effects {
            switch effect {
            case .chime:
                engine.chime()
            case .ask(let text):
                ask(text)
            case .speak(let words):
                engine.speak(words)
            case .hush:
                engine.hush()
            case .listen(let seconds):
                replyTimer?.cancel()
                replyTimer = Task { [weak self] in
                    try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                    guard !Task.isCancelled, let self else { return }
                    self.run(self.flow.silence())
                }
            case .settleSearch(let allowed):
                askedSearch = false
                audit.record(action: "voice_confirm", target: "web_search", outcome: allowed ? "yes" : "no")
                chat.answerSearchAsk(allowed)
            case .settleAction(let yes):
                settle(yes)
            case .endChat:
                awaited = nil
                chat.newChat()
            }
        }
        state = flow.state
        if state == .waiting || state == .off { hearing = "" }
    }

    private func ask(_ text: String) {
        askedSearch = false
        pendingAction = nil
        pendingEvent = nil
        let before = chat.conversation.messages.last?.id
        chat.askSpoken(text, style: persona.instruction())
        if chat.isAnswering, let answer = chat.conversation.messages.last, answer.id != before {
            awaited = answer.id
        } else {
            // Opening an app or changing a setting needs no answer from a model.
            awaited = nil
            run(flow.answered(chat.notice ?? "Done.", pending: nil))
        }
    }

    private func chatChanged(_ conversation: Conversation) {
        guard flow.state == .thinking, let awaited, let answer = conversation.messages.first(where: { $0.id == awaited }) else { return }
        if answer.state == .streaming {
            if answer.searchAsk?.state == .waiting, !askedSearch {
                askedSearch = true
                showChat()
                run(flow.answered("", pending: .searchQuestion))
            }
            return
        }
        self.awaited = nil
        switch answer.state {
        case .failed(let why):
            run(flow.failed(why))
        default:
            let waiting = pending(in: answer)
            // A preview is always put in front of the user, whether or not a spoken yes can confirm it.
            if waiting != nil { showChat() }
            run(flow.answered(answer.text, pending: waiting))
        }
    }

    /// What, if anything, the answer left waiting for the user.
    private func pending(in answer: ChatMessage) -> VoicePending? {
        for action in answer.actions where action.state == .waiting {
            if let summary = VoiceConfirm.summary(of: action) {
                pendingAction = action.id
                return .confirmable(summary: summary)
            }
            return .onScreen
        }
        for proposal in answer.proposals where proposal.state == .waiting {
            if let summary = VoiceConfirm.summary(of: proposal) {
                pendingEvent = proposal.id
                return .confirmable(summary: summary)
            }
            return .onScreen
        }
        return answer.projects.isEmpty ? nil : .onScreen
    }

    private func settle(_ yes: Bool) {
        if let id = pendingAction {
            audit.record(action: "voice_confirm", target: "action", outcome: yes ? "yes" : "no")
            if yes { chat.confirmAction(id) } else { chat.declineAction(id) }
        } else if let id = pendingEvent {
            audit.record(action: "voice_confirm", target: "event", outcome: yes ? "yes" : "no")
            if yes { chat.confirm(id) } else { chat.decline(id) }
        }
        pendingAction = nil
        pendingEvent = nil
    }
}
