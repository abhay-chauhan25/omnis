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
    /// Whether talking over OMNIS stops it. While this is on, the Mac's echo
    /// cancelling is used during a conversation so OMNIS hears less of itself.
    @Published var talkOver: Bool {
        didSet {
            UserDefaults.standard.set(talkOver, forKey: Self.talkOverKey)
            if !talkOver { engine.allowsInterruption = false; engine.setEchoCancelling(false) }
        }
    }
    /// How fast OMNIS talks: 1 is the voice's usual pace.
    @Published var speed: Double {
        didSet {
            UserDefaults.standard.set(speed, forKey: Self.speedKey)
            engine.speed = speed
        }
    }
    static let speeds: [(title: String, value: Double)] = [("Usual", 1.0), ("A little faster", 1.08), ("Faster", 1.16)]

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
    /// Something confirmed aloud that is being carried out; "Done" waits for it.
    private var actingAction: UUID?
    private var actingEvent: UUID?
    /// Set when a conversation ends. The chat is left as it is, so nothing the
    /// user is looking at disappears; the next "Hey OMNIS" starts a new one.
    private var freshNext = false
    private var watchdog: Task<Void, Never>?
    private var lastListen = VoiceFlow.replySeconds
    private var wasThinking = false
    /// How much of the answer being awaited has been said so far.
    private var stream = SpokenStream()
    /// When the question was put, for measuring how long the first words take.
    private var askedAt: Date?
    /// Development aid: where to write what is heard and done. Nothing is written unless OMNIS was started with it.
    private let traceFile: FileHandle?
    /// The longest an answer is waited for before the conversation gives up on it.
    static let answerSeconds = 240.0
    private static let personaKey = "OMNISVoicePersona"
    private static let switchKey = "OMNISVoiceOn"
    private static let talkOverKey = "OMNISVoiceTalkOver"
    private static let speedKey = "OMNISVoiceSpeed"

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

    init(chat: ChatModel, audit: AuditLog, autoStart: Bool = true, trace: URL? = nil, showChat: @escaping () -> Void = {}) {
        if let trace {
            FileManager.default.createFile(atPath: trace.path, contents: nil, attributes: [.posixPermissions: 0o600])
            traceFile = FileHandle(forWritingAtPath: trace.path)
        } else {
            traceFile = nil
        }
        talkOver = UserDefaults.standard.object(forKey: Self.talkOverKey) as? Bool ?? true
        let savedSpeed = UserDefaults.standard.double(forKey: Self.speedKey)
        speed = Self.speeds.contains { $0.value == savedSpeed } ? savedSpeed : 1.0
        self.chat = chat
        self.showChat = showChat
        self.audit = audit
        if let data = UserDefaults.standard.data(forKey: Self.personaKey), let saved = try? JSONDecoder().decode(VoicePersona.self, from: data) {
            persona = saved
        } else {
            persona = VoicePersona()
        }
        engine.speed = speed
        engine.onUtterance = { [weak self] words in self?.heard(words) }
        engine.onPartial = { [weak self] words in
            guard let self, self.inConversation else { return }
            self.hearing = String(words.suffix(120))
            // Words are being recognised: the speaker is given the full time again from here.
            // Sound alone does not count, so a television cannot hold the conversation open.
            if [.listening, .followUp, .confirming].contains(self.state) { self.listen(for: self.lastListen) }
        }
        engine.onLevel = { [weak self] level in
            // Outside a conversation nothing is drawn, so nothing is published.
            guard let self, self.inConversation else { return }
            // Smoothed, so the picture swells and settles rather than flickers.
            self.level = self.level * 0.6 + level * 0.4
        }
        engine.onDeviceChange = { [weak self] in
            // Headphones in or out: listening is started again on the new microphone.
            guard let self, self.isOn else { return }
            // An answer being read is cut short, so the conversation is not left waiting for it to finish.
            self.run(self.flow.interrupt())
            self.engine.stop()
            Task {
                do {
                    try await self.engine.start()
                    // Listening starts again without echo cancelling: it is put back if a conversation is going on.
                    if self.talkOver, self.inConversation { self.engine.setEchoCancelling(true) }
                    self.engine.allowsInterruption = self.talkOver && self.engine.echoCancelling && self.flow.canBeInterrupted
                } catch is CancellationError {} catch {
                    self.problem = error.localizedDescription
                    self.isOn = false
                }
            }
        }
        engine.onBargeIn = { [weak self] in
            guard let self else { return }
            self.audit.record(action: "voice", outcome: "talked over")
            self.run(self.flow.bargeIn())
        }
        engine.trace = { [weak self] line in self?.trace(line) }
        engine.onSpeechFinished = { [weak self] in
            guard let self else { return }
            self.run(self.flow.finishedSpeaking())
        }
        engine.onProblem = { [weak self] why in
            self?.problem = why
            self?.isOn = false
        }
        watching = chat.$conversation.sink { [weak self] _ in
            // The chat is read as it stands when this runs, never as it was when the change was
            // announced: one question changes the chat several times, and an earlier picture of
            // it, looked at late, has no answer in it yet.
            Task { @MainActor in
                guard let self else { return }
                self.chatChanged(self.chat.conversation)
            }
        }
        // The switch is remembered, so voice comes back on with OMNIS if it was left on.
        if autoStart, UserDefaults.standard.bool(forKey: Self.switchKey) { isOn = true }
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
                    // Switched off again while it was starting: nothing is left listening.
                    guard isOn, engine.isRunning else { return }
                    run(flow.switchOn())
                } catch is CancellationError {
                } catch {
                    problem = error.localizedDescription
                    isOn = false
                }
            }
        } else {
            replyTimer?.cancel()
            watchdog?.cancel()
            awaited = nil
            actingAction = nil
            actingEvent = nil
            pendingAction = nil
            pendingEvent = nil
            run(flow.switchOff())
            engine.stop()
            state = .off
            level = 0
            hearing = ""
        }
    }

    // MARK: Rehearsal (development aid)

    private struct Rehearsal {
        var lines: [String]
        let report: (String) -> Void
        let finished: () -> Void
    }
    private var rehearsal: Rehearsal?

    /// Runs a spoken conversation with no microphone and no sound: each line is
    /// taken as if it had been heard, and what OMNIS would say is reported.
    /// Everything else is real, including the answers.
    func rehearse(_ lines: [String], report: @escaping (String) -> Void, finished: @escaping () -> Void) {
        rehearsal = Rehearsal(lines: lines, report: report, finished: finished)
        run(flow.switchOn())
        rehearseNext()
    }

    private func rehearseNext() {
        guard var current = rehearsal else { return }
        guard !current.lines.isEmpty else {
            rehearsal = nil
            current.finished()
            return
        }
        let line = current.lines.removeFirst()
        rehearsal = current
        current.report("YOU SAY: \(line)")
        Task { @MainActor [weak self] in
            guard let self else { return }
            let before = self.flow.state
            self.run(self.flow.heard(line))
            // Something said that nothing was listening for: on to the next line.
            if self.flow.state == before, before == .waiting { self.rehearseNext() }
        }
    }

    private func trace(_ line: String) {
        guard let traceFile else { return }
        traceFile.write(Data(String(format: "%.2f  %@\n", Date().timeIntervalSince1970.truncatingRemainder(dividingBy: 10_000), line).utf8))
    }

    /// Stops listening as OMNIS quits, without forgetting that the switch was on.
    func stopForQuit() {
        replyTimer?.cancel()
        engine.stop()
    }

    /// Ends the conversation now, from a button. It always works, whatever was heard or not heard.
    func endConversation() {
        replyTimer?.cancel()
        awaited = nil
        actingAction = nil
        actingEvent = nil
        run(flow.end())
        level = 0
    }

    /// Cuts short what is being read aloud.
    func interrupt() {
        run(flow.interrupt())
    }

    private func heard(_ words: String) {
        replyTimer?.cancel()
        hearing = ""
        trace("heard (\(flow.state)): \(words)")
        // A typed question is being answered: voice waits its turn.
        if flow.state == .waiting, chat.isAnswering { return }
        run(flow.heard(words))
    }

    private func listen(for seconds: Double) {
        lastListen = seconds
        replyTimer?.cancel()
        replyTimer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.run(self.flow.silence())
        }
    }

    private func run(_ effects: [VoiceFlow.Effect]) {
        for effect in effects {
            switch effect {
            case .chime:
                // A new conversation starts in a new chat, unless a typed question is being answered in this one.
                if freshNext {
                    freshNext = false
                    chat.startFreshForVoice()
                }
                engine.chime()
                // Claude is started now, so that it is ready by the time the question has been said.
                chat.warmForVoice()
            case .ask(let text):
                ask(text)
            case .speak(let words):
                trace("says: \(words)")
                if let asked = askedAt {
                    // How long the first words took, and nothing about what they were.
                    askedAt = nil
                    let waited = Date().timeIntervalSince(asked)
                    trace(String(format: "first words after %.1f s", waited))
                    audit.record(action: "voice_timing", outcome: "ok", detail: String(format: "first words after %.1f s", waited))
                }
                if let rehearsal {
                    // A rehearsal makes no sound: what would be said is reported instead.
                    rehearsal.report("OMNIS SAYS: \(words)")
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard let self else { return }
                        self.run(self.flow.finishedSpeaking())
                    }
                } else {
                    engine.speak(words)
                }
            case .hush:
                engine.hush()
            case .stopAnswer:
                // Only an answer voice asked for is stopped, never one typed for in the window.
                if awaited != nil {
                    awaited = nil
                    chat.stop()
                    // Stopping ends Claude's session; it is started again while the user talks.
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(nanoseconds: 500_000_000)
                        // Not if the conversation was ended meanwhile.
                        guard let self, self.inConversation else { return }
                        self.chat.warmForVoice()
                    }
                }
            case .listen(let seconds):
                if rehearsal != nil { rehearseNext() } else { listen(for: seconds) }
            case .settleSearch(let allowed):
                askedSearch = false
                audit.record(action: "voice_confirm", target: "web_search", outcome: allowed ? "yes" : "no")
                chat.answerSearchAsk(allowed)
            case .settleAction(let yes):
                settle(yes)
            case .endChat:
                awaited = nil
                freshNext = true
                if rehearsal == nil, isOn { engine.closingChime() }
                rehearsal?.report("(conversation ended)")
                if rehearsal != nil { rehearseNext() }
            }
        }
        if state != flow.state { trace("now \(flow.state)") }
        state = flow.state
        if state == .waiting || state == .off { hearing = "" }
        // Only with echo cancelling on: without it OMNIS would hear itself and take that for the user.
        engine.allowsInterruption = talkOver && engine.echoCancelling && flow.canBeInterrupted
        // Echo cancelling is on from the first answer until the conversation ends, and off the rest of the time.
        if state == .waiting || state == .off { engine.setEchoCancelling(false) } else if state == .thinking, talkOver { engine.setEchoCancelling(true) }
        let entering = flow.awaitsAnswer && !wasThinking
        wasThinking = flow.awaitsAnswer
        if !flow.awaitsAnswer { watchdog?.cancel() }
        if state == .thinking {
            // The answer may already be there, or the chat may have been cleared from the window.
            Task { @MainActor [weak self] in
                guard let self, self.flow.state == .thinking else { return }
                self.chatChanged(self.chat.conversation)
            }
        }
        // The limit runs from the moment thinking began, whatever else is heard meanwhile.
        if entering {
            watchdog?.cancel()
            // And nothing is waited for without end.
            watchdog = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.answerSeconds * 1_000_000_000))
                guard !Task.isCancelled, let self, self.flow.awaitsAnswer else { return }
                self.awaited = nil
                self.actingAction = nil
                self.actingEvent = nil
                self.run(self.flow.failed("No answer came."))
            }
        }
    }

    private func ask(_ text: String) {
        askedSearch = false
        pendingAction = nil
        pendingEvent = nil
        // A typed question is still being answered: the spoken one is not dropped silently.
        guard !chat.isAnswering else {
            awaited = nil
            run(flow.failed("I am still answering the last question."))
            return
        }
        stream = SpokenStream()
        askedAt = Date()
        switch chat.askSpoken(text, style: persona.instruction()) {
        case .asked:
            // Usually still being written. If it failed at once, `chatChanged` says so.
            awaited = chat.conversation.messages.last.flatMap { $0.role == .assistant ? $0.id : nil }
            if awaited == nil { run(flow.failed("The question could not be asked.")) }
        case .opened(let name):
            // Opened without asking a model. It reports for itself on screen as well.
            awaited = nil
            run(flow.answered("Opening \(name).", pending: nil))
        case .command:
            awaited = nil
            run(flow.answered("Okay.", pending: nil))
        case .nothing:
            awaited = nil
            run(flow.failed("I am still answering the last question."))
        }
    }

    private func chatChanged(_ conversation: Conversation) {
        guard flow.awaitsAnswer else { return }
        // Something confirmed aloud is being carried out: say how it went, once it has gone.
        if actingAction != nil || actingEvent != nil {
            let state = actingAction.flatMap { conversation.action($0)?.state } ?? actingEvent.flatMap { id in
                conversation.messages.lazy.flatMap(\.proposals).first { $0.id == id }?.state
            }
            switch state {
            case .done?:
                actingAction = nil; actingEvent = nil
                run(flow.acted(success: true))
            case .failed(let why)?:
                actingAction = nil; actingEvent = nil
                run(flow.acted(success: false, detail: why))
            case nil, .declined?, .replaced?:
                // Gone from the chat, or settled some other way.
                actingAction = nil; actingEvent = nil
                run(flow.acted(success: false, detail: "It is no longer waiting."))
            case .waiting?, .saving?:
                break
            }
            return
        }
        guard let awaited else { return }
        guard let answer = conversation.messages.first(where: { $0.id == awaited }) else {
            // The chat was cleared from the window while the answer was awaited.
            self.awaited = nil
            run(flow.failed("That chat was closed."))
            return
        }
        if answer.state == .streaming {
            if answer.searchAsk?.state == .waiting, !askedSearch {
                askedSearch = true
                showChat()
                // Whole sentences only: the rest of the answer follows once the question is settled.
                run(flow.answered(stream.take(answer.text, final: false), pending: .searchQuestion))
                return
            }
            // What has been written so far is said while the rest arrives. A question
            // waiting on the user is asked first, and nothing is said over it.
            if answer.searchAsk?.state != .waiting {
                let ready = stream.take(answer.text, final: false)
                if !ready.isEmpty { run(flow.streamed(ready)) }
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
            run(flow.answered(stream.take(answer.text, final: true), pending: waiting))
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
            if yes { actingAction = id; chat.confirmAction(id) } else { chat.declineAction(id) }
        } else if let id = pendingEvent {
            audit.record(action: "voice_confirm", target: "event", outcome: yes ? "yes" : "no")
            if yes { actingEvent = id; chat.confirm(id) } else { chat.decline(id) }
        } else if yes {
            // Nothing was waiting after all. `chatChanged` reports that it could not be done.
            actingAction = UUID()
        }
        pendingAction = nil
        pendingEvent = nil
    }
}
