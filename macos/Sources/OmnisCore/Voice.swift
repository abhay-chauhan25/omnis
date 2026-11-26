import Foundation

/// The words OMNIS listens for and how it turns an answer into speech.
public enum VoicePhrases {
    // "Omnis" is not a word a recogniser knows, so near misses count: it is often heard as "Omnes".
    private static let wake = try! NSRegularExpression(
        pattern: #"\b(?:(?:hey|hay|hi|okay|ok|kay|k|yo)[\s,.!]*(?:omn[iea]s|omni's|omni|omnus|omniss|omness|amnis|omnious)|(?:hey|hay|yo)[\s,.!]+(?:omi|omie|omy|omee))\b[\s,.!?:;\-]*"#,
        options: [.caseInsensitive])

    /// What was said after "Hey OMNIS", or nil if the phrase is not there.
    /// Empty when the phrase was all that was said.
    public static func afterWake(_ heard: String) -> String? {
        let whole = NSRange(heard.startIndex..., in: heard)
        guard let match = wake.firstMatch(in: heard, range: whole), let range = Range(match.range, in: heard) else { return nil }
        return String(heard[range.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// What was said, reduced to its words: no capitals, no punctuation, and no
    /// apostrophes, which a recogniser writes in more than one way ("that's", "that’s", "thats").
    static func plain(_ text: String) -> String {
        var kept = ""
        for character in text.lowercased() {
            if "'\u{2019}\u{2018}\u{02BC}`".contains(character) { continue }
            if character.isLetter || character.isNumber { kept.append(character) } else { kept.append(" ") }
        }
        return kept.split(separator: " ").joined(separator: " ")
    }

    // Said alone, each of these ends the conversation.
    private static let endings: Set<String> = [
        "no", "nope", "nah", "no thanks", "no thank you", "no thats all", "no thats it", "no im good", "nothing", "nothing thanks",
        // How a short "no" is sometimes heard.
        "know", "no no", "noo",
        "bye", "bye bye", "goodbye", "good bye", "thanks", "thank you", "thanks omnis", "thank you omnis", "stop", "done", "all done",
        "im done", "im good", "all good", "were done", "we are done", "i am done", "end chat", "end the chat", "stop listening",
    ]
    // Said anywhere in a short remark, each of these ends it too: "okay, that's all for now", "yeah that's it thanks".
    private static let endingPhrases = [
        "thats all", "that is all", "that will be all", "thatll be all", "that would be all", "thats it", "that is it", "thats everything",
        "nothing else", "nothing more", "no more", "im done", "i am done", "were done", "we are done", "im all set", "all set",
        "goodbye", "good bye", "stop listening", "end chat", "end the chat", "that is everything", "im good", "all good",
    ]

    /// True when what was said is a way of ending the conversation: one of the
    /// endings on its own, or a short remark with an ending phrase in it. A
    /// longer sentence is a request, whatever words it happens to contain.
    public static func isEnding(_ heard: String) -> Bool {
        var said = plain(heard)
        // Fillers at the start do not change what is meant.
        for filler in ["okay ", "ok ", "yeah ", "yes ", "yep ", "um ", "uh ", "oh ", "well ", "so ", "alright ", "all right ", "right ", "omnis ", "hey omnis "] {
            while said.hasPrefix(filler) { said.removeFirst(filler.count) }
        }
        guard !said.isEmpty else { return false }
        if endings.contains(said) { return true }
        guard said.split(separator: " ").count <= 6 else { return false }
        let padded = " \(said) "
        return endingPhrases.contains { padded.contains(" \($0) ") }
    }

    private static let yes: Set<String> = ["yes", "yeah", "yep", "yup", "sure", "ok", "okay", "go ahead", "do it", "send it", "please do", "yes please",
                                           "confirm", "confirmed", "thats right", "correct", "go for it", "yes go ahead", "yes send it", "yes do it", "absolutely",
                                           "yes thats right", "yeah go ahead", "yeah send it", "sure go ahead"]
    private static let no: Set<String> = ["no", "nope", "nah", "dont", "do not", "cancel", "stop", "no thanks", "no thank you", "dont send it",
                                          "no dont", "never mind", "nevermind", "leave it", "not now", "no cancel", "no dont send it"]

    /// Whether a spoken reply to a yes-or-no question was a yes, a no, or neither.
    /// Only a clear, short yes counts: "yes but change the time" is neither.
    public static func yesOrNo(_ heard: String) -> Bool? {
        let said = plain(heard)
        if yes.contains(said) { return true }
        if no.contains(said) { return false }
        return nil
    }

    private static let cleaners: [(NSRegularExpression, String)] = [
        (#"```[\s\S]*?```"#, " (there is some code on screen) "), (#"`([^`]*)`"#, "$1"),
        (#"\[([^\]]+)\]\((https?://[^)]+)\)"#, "$1"), (#"https?://\S+"#, "a link"), (#"\[\d+\]"#, ""),
        (#"(?m)^\s{0,3}#{1,6}\s*"#, ""), (#"(?m)^\s*[-*•]\s+"#, ""), (#"(?m)^\s*\d+[.)]\s+"#, ""),
        (#"\*\*([^*]+)\*\*"#, "$1"), (#"\*([^*]+)\*"#, "$1"), (#"__([^_]+)__"#, "$1"), (#"\s*\n+\s*"#, ". "), (#"\.\s*\.(\s*\.)*"#, "."), (#"[ \t]{2,}"#, " "),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    /// An answer as it should be read aloud: no markup, no addresses, no source marks.
    public static func spoken(_ answer: String, limit: Int = 1_800) -> String {
        var text = answer
        for (pattern, replacement) in cleaners {
            text = pattern.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: replacement)
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.count > limit else { return text }
        // A long answer is read up to the last full sentence that fits; the rest is on screen.
        let head = String(text.prefix(limit))
        let end = head.lastIndex(where: { ".!?".contains($0) }).map { head[...$0] } ?? Substring(head)
        return String(end) + " The rest is on screen."
    }
}

/// Turns an answer into speech while it is still being written: each time more
/// of it arrives, the sentences that are now complete are handed on to be said.
/// The first words are heard long before the last ones are written.
public struct SpokenStream: Equatable, Sendable {
    /// How many characters of the answer have been handed on.
    private var taken = 0
    private var said = 0
    private var cutShort = false
    private let limit: Int

    public init(limit: Int = 1_800) {
        self.limit = limit
    }

    /// True once something has been handed on to be said.
    public var hasSpoken: Bool { said > 0 }

    // A full stop after one of these is not the end of a sentence.
    private static let shortForms: Set<String> = ["mr", "mrs", "ms", "dr", "vs", "st", "e.g", "i.e", "eg", "ie", "no", "approx"]

    /// How far the answer can be read aloud: just past the last sentence that has ended.
    static func boundary(in text: [Character], from start: Int) -> Int {
        var best = start
        var inCode = false
        var index = 0
        while index < text.count {
            // Code is never read in pieces: it is passed over whole, once it has closed.
            if text[index] == "`", index + 2 < text.count, text[index + 1] == "`", text[index + 2] == "`" {
                inCode.toggle()
                index += 3
                continue
            }
            defer { index += 1 }
            guard !inCode, index >= start else { continue }
            if text[index] == "\n" {
                best = index + 1
            } else if ".!?".contains(text[index]), index + 1 < text.count, text[index + 1].isWhitespace {
                if text[index] == "." {
                    var back = index
                    while back > 0, !text[back - 1].isWhitespace { back -= 1 }
                    let word = String(text[back..<index]).lowercased()
                    // "Dr. Jones", "J. Smith", and the "1." of a numbered line.
                    let startsLine = back == 0 || text[back - 1] == "\n"
                    if shortForms.contains(word) || (word.count == 1 && !word.allSatisfy(\.isNumber))
                        || (startsLine && !word.isEmpty && word.allSatisfy(\.isNumber)) { continue }
                }
                best = index + 1
            }
        }
        return best
    }

    /// Takes the answer as it stands and returns what can now be said, or
    /// nothing. With `final`, everything left is returned.
    public mutating func take(_ answer: String, final: Bool) -> String {
        let text = Array(answer)
        // The answer was replaced by a shorter one: nothing more of it is read.
        guard taken <= text.count else { return "" }
        let end = final ? text.count : Self.boundary(in: text, from: taken)
        guard end > taken else { return "" }
        let piece = String(text[taken..<end])
        taken = end
        guard !cutShort else { return "" }
        var words = VoicePhrases.spoken(piece.trimmingCharacters(in: .whitespacesAndNewlines), limit: Int.max).replacingOccurrences(of: "*", with: "").replacingOccurrences(of: "`", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard words.contains(where: { $0.isLetter || $0.isNumber }) else { return "" }
        if said + words.count > limit {
            // A long answer is read up to the last full sentence that fits; the rest is on screen.
            cutShort = true
            let head = String(words.prefix(max(0, limit - said)))
            let whole = head.lastIndex(where: { ".!?".contains($0) }).map { String(head[...$0]) } ?? ""
            words = (whole.isEmpty ? "" : whole + " ") + "The rest is on screen."
        }
        said += words.count
        return words
    }
}

/// Telling the user's voice from OMNIS's own, heard back through the microphone.
public enum VoiceEcho {
    // Said over OMNIS, any of these is enough to stop it.
    private static let halting: Set<String> = ["stop", "wait", "omnis", "pause", "quiet", "enough", "hold"]

    /// True when what was heard while OMNIS was talking is someone else speaking,
    /// rather than its own words coming back. Its own words are known, so
    /// the latest few words heard, if most of them are not its own, are taken as the user.
    public static func isInterruption(heard: String, speaking: String) -> Bool {
        let own = Set(VoicePhrases.plain(speaking).split(separator: " "))
        // Only the latest words count: what came back earlier in a long answer says nothing about now.
        let recent = VoicePhrases.plain(heard).split(separator: " ").suffix(5)
        let foreign = recent.filter { !own.contains($0) }
        guard !foreign.isEmpty else { return false }
        if recent.suffix(3).contains(where: { halting.contains(String($0)) && !own.contains($0) }) { return true }
        // One stray word is a mishearing; most of the last few is a person.
        return foreign.count >= max(2, (recent.count * 3 + 4) / 5)
    }
}

public extension VoiceEcho {
    /// How many words at the start of what was heard are OMNIS's own voice
    /// coming back, at the moment the user talked over it. Everything before
    /// the last few words is, and so are those of the last few that are its own.
    static func ownWords(atStartOf heard: String, speaking: String) -> Int {
        let own = Set(VoicePhrases.plain(speaking).split(separator: " "))
        let words = heard.split(whereSeparator: \.isWhitespace)
        var count = max(0, words.count - 5)
        while count < words.count, VoicePhrases.plain(String(words[count])).split(separator: " ").allSatisfy({ own.contains($0) }) { count += 1 }
        return count
    }

    /// What the user said when they talked over OMNIS, picked out word by word.
    /// Each word comes with the moment it was said. A word said while OMNIS
    /// was still audible is kept only if it is not one of OMNIS's own; every
    /// word said after that is kept.
    static func usersWords(_ words: [(text: String, at: Double?)], speaking: String, ownUntil: Double) -> String {
        let own = Set(VoicePhrases.plain(speaking).split(separator: " "))
        let kept = words.filter { word in
            guard let at = word.at, at < ownUntil else { return true }
            let parts = VoicePhrases.plain(word.text).split(separator: " ")
            return !parts.isEmpty && !parts.allSatisfy { own.contains($0) }
        }
        return kept.map(\.text).joined().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// What was heard, without that many words at its start.
    static func dropping(_ count: Int, from heard: String) -> String {
        heard.split(whereSeparator: \.isWhitespace).dropFirst(count).joined(separator: " ")
    }
}

/// Keeps what the recogniser has heard since the last thing was acted on.
///
/// The recogniser reports a stretch of speech many times as it grows, then
/// once more as settled ("final"), often worded a little differently. Settled
/// stretches are kept in order; the one still growing replaces itself.
public struct UtteranceBuffer: Equatable, Sendable {
    private var settled: [(end: Double, text: String)] = []
    private var growing = ""
    private var cutoff = -1.0
    private var latest = 0.0
    /// Set after OMNIS has spoken: nothing still growing is believed until a
    /// settled stretch has gone by, because it may be the end of OMNIS's own voice.
    private var wary = false
    /// True when everything heard so far has been settled.
    public private(set) var isSettled = true

    public init() {}

    public static func == (a: UtteranceBuffer, b: UtteranceBuffer) -> Bool { a.current == b.current && a.isSettled == b.isSettled }

    public mutating func take(_ text: String, start: Double, end: Double, final: Bool) {
        guard start.isFinite, end.isFinite else { return }
        if final {
            latest = max(latest, end)
            // A settled stretch is kept only if it began after the cut. One that
            // began before it was already acted on, or was OMNIS's own voice.
            if wary ? start >= cutoff - 0.05 : end > cutoff + 0.001 { settled.append((end, text)) }
            wary = false
            growing = ""
            isSettled = true
        } else {
            guard !wary else { return }
            growing = text
            isSettled = text.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }

    /// Everything heard since the last cut.
    public var current: String {
        (settled.map(\.text) + [growing]).joined(separator: " ").split(separator: " ").joined(separator: " ")
    }

    /// Forgets what has been heard. `upTo` is how far into the sound that covers.
    /// `afterOwnVoice` is for the moment OMNIS stops speaking: from then only
    /// speech that begins after `time` is believed.
    public mutating func cut(upTo time: Double? = nil, afterOwnVoice: Bool = false) {
        cutoff = max(cutoff, time ?? latest)
        settled.removeAll()
        growing = ""
        isSettled = true
        if afterOwnVoice { wary = true }
    }
}

/// How OMNIS talks when it is spoken to: a preset, the user's own words, or both.
public struct VoicePersona: Codable, Equatable, Sendable {
    public struct Preset: Equatable, Sendable, Identifiable {
        public let id: String
        public let title: String
        public let manner: String
    }

    public static let presets: [Preset] = [
        Preset(id: "calm", title: "Calm and brief", manner: "Calm, clear and economical. Say what matters and stop."),
        Preset(id: "warm", title: "Warm and chatty", manner: "Warm, friendly and a little chatty, like a good friend who is glad to help."),
        Preset(id: "witty", title: "Dry and witty", manner: "Dry, quick and lightly witty. One wry remark at most, never at the user's expense."),
        Preset(id: "upbeat", title: "Upbeat and encouraging", manner: "Upbeat and encouraging, with energy but no gushing."),
        Preset(id: "plain", title: "No particular manner", manner: ""),
    ]
    public static let maxCustomCharacters = 400

    public var preset: String
    /// The user's own description, added to the preset.
    public var custom: String

    public init(preset: String = "calm", custom: String = "") {
        self.preset = preset
        self.custom = custom
    }

    /// What Claude is told about a spoken message. Manner only: it gives no
    /// permission and changes no rule.
    public func instruction() -> String {
        var lines = ["[This message was spoken aloud to you, and your reply will be read aloud. Reply the way a person speaks: "
            + "two or three short sentences unless more is asked for, no lists, headings, symbols or web addresses, and numbers "
            + "and times as they are said. Lead with the answer itself. Do not end by asking whether there is anything else."]
        let manner = Self.presets.first { $0.id == preset }?.manner ?? ""
        let own = String(custom.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxCustomCharacters))
            .replacingOccurrences(of: "[", with: "(").replacingOccurrences(of: "]", with: ")")
        if !manner.isEmpty { lines.append("Your manner: \(manner)") }
        if !own.isEmpty { lines.append("The user's own description of how you should sound: \(own)") }
        if !manner.isEmpty || !own.isEmpty {
            lines.append("This is about tone only. It never changes what you may do, what needs the user's confirmation, or how careful you are with facts.")
        }
        return lines.joined(separator: " ") + "]"
    }
}

/// Something waiting on the user when an answer has been given.
public enum VoicePending: Equatable, Sendable {
    /// "May this chat search the web?" The answer is paused until it is settled.
    case searchQuestion
    /// A preview that a spoken yes may confirm. `summary` is read out first.
    case confirmable(summary: String)
    /// A preview that needs a click.
    case onScreen
}

/// Which previews a spoken "yes" may confirm, as the user chose: adding a
/// reminder or an event, and sending a message. Everything else needs a click.
public enum VoiceConfirm {
    public static let spokenKinds: Set<String> = ["add_reminder", "create_event", "send_message"]

    /// What is read out before asking, so the user hears exactly what a yes would do.
    public static func summary(of action: ActionProposal) -> String? {
        guard spokenKinds.contains(action.kind), action.state == .waiting else { return nil }
        if action.kind == "send_message" {
            let words = action.payload["text"] ?? ""
            return "A message \(action.title.prefix(1).lowercased() + action.title.dropFirst()), saying: \(words)."
        }
        let due = action.rows.first { $0.label == "Due" }.map { ", due \($0.value)" } ?? ""
        return "A reminder: \(action.title)\(due)."
    }

    public static func summary(of proposal: EventProposal) -> String? {
        guard spokenKinds.contains(proposal.change.kind), proposal.state == .waiting else { return nil }
        return "A new event: \(proposal.change.line())."
    }
}

/// The back-and-forth of a spoken conversation, with nothing in it that
/// listens or speaks: it is told what happened and says what to do next.
public struct VoiceFlow: Equatable, Sendable {
    public enum State: Equatable, Sendable {
        case off
        /// Listening only for "Hey OMNIS".
        case waiting
        /// Heard the phrase; listening for what is wanted.
        case listening
        case thinking
        case speaking
        /// Has answered, and is listening for whatever comes next.
        case followUp
        /// Asked a yes-or-no question and listening for the reply.
        case confirming
    }

    public enum Question: Equatable, Sendable { case search, action }

    public enum Effect: Equatable, Sendable {
        case chime
        case ask(String)
        case speak(String)
        /// Start listening for a reply, for up to this many seconds.
        case listen(seconds: Double)
        case settleSearch(Bool)
        case settleAction(Bool)
        /// The conversation is over: the next one starts in a new chat.
        case endChat
        /// A spoken answer that was being read is cut short.
        case hush
        /// The answer still being written is no longer wanted.
        case stopAnswer
    }

    public private(set) var state: State = .off
    private var afterSpeaking: State = .followUp
    private var question: Question?
    private var retried = false
    private var endAfterSpeaking = false
    /// The answer is being read while it is still being written: more is on its way.
    private var moreComing = false
    private var spokeSome = false
    /// True while the voice has something left to say.
    private var voiceBusy = false

    /// True while an answer is awaited or still arriving.
    public var awaitsAnswer: Bool { state == .thinking || (state == .speaking && moreComing) }
    /// True when the user may talk over what is being said. A yes-or-no question
    /// is always heard out, so that nothing said over it is taken for an answer.
    public var canBeInterrupted: Bool {
        state == .speaking && !endAfterSpeaking && (moreComing || afterSpeaking == .followUp)
    }

    public static let replySeconds = 8.0
    public init() {}

    public mutating func switchOn() -> [Effect] {
        guard state == .off else { return [] }
        state = .waiting
        return []
    }

    public mutating func switchOff() -> [Effect] {
        let wasTalking = state == .speaking
        // Nothing is carried over to the next time it is switched on.
        self = VoiceFlow()
        return wasTalking ? [.hush] : []
    }

    /// Something was said and the speaker has stopped.
    public mutating func heard(_ said: String) -> [Effect] {
        let words = said.trimmingCharacters(in: .whitespacesAndNewlines)
        switch state {
        case .off, .thinking, .speaking:
            return []
        case .waiting:
            guard let rest = VoicePhrases.afterWake(words) else { return [] }
            if rest.isEmpty {
                state = .listening
                return [.chime, .listen(seconds: Self.replySeconds)]
            }
            state = .thinking
            return [.chime, .ask(rest)]
        case .listening, .followUp:
            // Saying the phrase again is fine; it is not part of the request.
            let request = VoicePhrases.afterWake(words) ?? words
            guard !request.isEmpty else { return [.listen(seconds: Self.replySeconds)] }
            if VoicePhrases.isEnding(request) { return finish(saying: state == .followUp ? "Okay." : nil) }
            state = .thinking
            return [.ask(request)]
        case .confirming:
            guard let asked = question else { return finish(saying: nil) }
            guard let yes = VoicePhrases.yesOrNo(words) else {
                if retried { return leaveOnScreen(asked) }
                retried = true
                return say("Sorry, was that a yes or a no?", then: .confirming)
            }
            question = nil
            retried = false
            switch asked {
            case .search:
                // The answer that was waiting carries on, or is told no.
                state = .thinking
                return [.settleSearch(yes)]
            case .action:
                if yes {
                    // Nothing is said to be done until it is: `acted` is told how it went.
                    state = .thinking
                    return [.settleAction(true)]
                }
                return [.settleAction(false)] + say("Okay, I have left it.", then: .followUp)
            }
        }
    }

    /// Nobody spoke in the time allowed.
    public mutating func silence() -> [Effect] {
        switch state {
        case .listening:
            state = .waiting
            return []
        case .followUp:
            return finish(saying: nil)
        case .confirming:
            guard let asked = question else { return finish(saying: nil) }
            return leaveOnScreen(asked)
        case .off, .waiting, .thinking, .speaking:
            return []
        }
    }

    /// Part of the answer has been written and can be said while the rest arrives.
    public mutating func streamed(_ words: String) -> [Effect] {
        guard awaitsAnswer, !words.isEmpty else { return [] }
        state = .speaking
        moreComing = true
        spokeSome = true
        voiceBusy = true
        afterSpeaking = .followUp
        return [.speak(words)]
    }

    /// The answer has arrived, or has paused on a question for the user. `text`
    /// is whatever of it has not been said yet.
    public mutating func answered(_ text: String, pending: VoicePending?) -> [Effect] {
        guard awaitsAnswer else { return [] }
        let answer = VoicePhrases.spoken(text)
        let hadSpoken = spokeSome
        moreComing = false
        spokeSome = false
        switch pending {
        case .searchQuestion:
            question = .search
            retried = false
            return say([answer, "This chat holds personal information. Shall I search the web? Yes or no?"].filter { !$0.isEmpty }.joined(separator: " "),
                       then: .confirming)
        case .confirmable(let summary):
            question = .action
            retried = false
            // The question ends on words that are not themselves an answer, in case OMNIS hears the end of its own voice.
            return say([answer, summary, "Shall I do that? Yes or no?"].filter { !$0.isEmpty }.joined(separator: " "), then: .confirming)
        case .onScreen:
            return say([answer, "It is on screen for you to confirm."].filter { !$0.isEmpty }.joined(separator: " "), then: .followUp)
        case nil:
            // Nothing more is asked: OMNIS simply listens for whatever comes next.
            return conclude(answer.isEmpty && !hadSpoken ? "I have nothing to say to that." : answer, then: .followUp)
        }
    }

    /// Something confirmed aloud has been carried out, or could not be.
    public mutating func acted(success: Bool, detail: String = "") -> [Effect] {
        guard state == .thinking else { return [] }
        let why = VoicePhrases.spoken(detail, limit: 200)
        return say(success ? "Done." : "That did not work. \(why)".trimmingCharacters(in: .whitespaces), then: .followUp)
    }

    /// The answer could not be given.
    public mutating func failed(_ why: String) -> [Effect] {
        guard awaitsAnswer else { return [] }
        moreComing = false
        spokeSome = false
        return say("Sorry, that did not work. \(VoicePhrases.spoken(why, limit: 200))".trimmingCharacters(in: .whitespaces), then: .followUp)
    }

    public mutating func finishedSpeaking() -> [Effect] {
        guard state == .speaking else { return [] }
        voiceBusy = false
        // Everything written so far has been said; the rest is still being written.
        if moreComing {
            state = .thinking
            return []
        }
        if endAfterSpeaking {
            endAfterSpeaking = false
            state = .waiting
            return [.endChat]
        }
        state = afterSpeaking
        return [.listen(seconds: Self.replySeconds)]
    }

    /// The user ended the conversation with a button, whatever was going on.
    public mutating func end() -> [Effect] {
        guard state != .off, state != .waiting else { return [] }
        let wasSpeaking = state == .speaking, wasWaiting = awaitsAnswer
        self = VoiceFlow()
        state = .waiting
        return (wasSpeaking ? [.hush] : []) + (wasWaiting ? [.stopAnswer] : []) + [.endChat]
    }

    /// The user cut the reading short with a key or a button.
    public mutating func interrupt() -> [Effect] {
        guard state == .speaking else { return [] }
        if moreComing { return takeOver() }
        return [.hush] + finishedSpeaking()
    }

    /// The user started talking over OMNIS: it stops, drops the rest of what
    /// it was saying, and listens.
    public mutating func bargeIn() -> [Effect] {
        guard canBeInterrupted else { return [] }
        return takeOver()
    }

    private mutating func takeOver() -> [Effect] {
        let unfinished = moreComing
        moreComing = false
        spokeSome = false
        voiceBusy = false
        state = .followUp
        return [.hush] + (unfinished ? [.stopAnswer] : []) + [.listen(seconds: Self.replySeconds)]
    }

    /// Says the words, if there are any, and then listens.
    private mutating func conclude(_ words: String, then next: State) -> [Effect] {
        guard words.isEmpty else { return say(words, then: next) }
        if voiceBusy {
            // The last sentence is still being said.
            state = .speaking
            afterSpeaking = next
            return []
        }
        state = next
        return [.listen(seconds: Self.replySeconds)]
    }

    private mutating func say(_ words: String, then next: State) -> [Effect] {
        state = .speaking
        afterSpeaking = next
        voiceBusy = true
        return [.speak(words)]
    }

    private mutating func finish(saying words: String?) -> [Effect] {
        question = nil
        retried = false
        guard let words else {
            state = .waiting
            return [.endChat]
        }
        endAfterSpeaking = true
        state = .speaking
        voiceBusy = true
        return [.speak(words)]
    }

    /// No clear answer: nothing is confirmed, and the question stays on screen.
    private mutating func leaveOnScreen(_ asked: Question) -> [Effect] {
        question = nil
        retried = false
        switch asked {
        case .search:
            // Without a clear yes there is no search. The answer that was waiting carries on without one.
            state = .thinking
            return [.settleSearch(false)]
        case .action:
            return say("I have left it on screen for you.", then: .followUp)
        }
    }
}
