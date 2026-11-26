import AppKit
import AVFoundation
import OmnisCore
import OmnisObjC
import Speech

enum VoiceProblem: Error, LocalizedError {
    case noMicrophone
    case notSupported
    case couldNotStart(String)

    var errorDescription: String? {
        switch self {
        case .noMicrophone:
            return "OMNIS has not been allowed to use the microphone. You can allow it in System Settings, under Privacy & Security, Microphone."
        case .notSupported: return "Speech recognition for English is not available on this Mac."
        case .couldNotStart(let why): return "Listening could not be started: \(why)"
        }
    }
}

/// The microphone, the speech recogniser and the speaking voice. All three
/// are Apple's own and run on this Mac: no sound leaves it. What is heard is
/// handed on as text and kept nowhere here.
@MainActor
final class VoiceEngine: NSObject, AVSpeechSynthesizerDelegate {
    /// The speaker stopped. The words since the last utterance.
    var onUtterance: ((String) -> Void)?
    /// Words as they are being heard, before the speaker stops.
    var onPartial: ((String) -> Void)?
    /// How loud the room or the voice is, from 0 to 1.
    var onLevel: ((Double) -> Void)?
    var onSpeechFinished: (() -> Void)?
    /// The user started talking while OMNIS was. Its voice has already been stopped.
    var onBargeIn: (() -> Void)?
    /// Whether talking over OMNIS stops it. Off while it asks a yes-or-no question.
    var allowsInterruption = false
    /// How fast OMNIS talks: 1 is the voice's usual pace.
    var speed = 1.0
    /// Development aid: told what is heard and done, for a log that is only written when asked for.
    var trace: ((String) -> Void)?
    var onProblem: ((String) -> Void)?

    /// Made afresh each time listening starts or changes, so it always takes the microphone as it now is.
    private var audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var buffer = UtteranceBuffer()
    /// How far into the sound the recogniser has got.
    private var soundTime = 0.0
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking = false
    /// Everything OMNIS has said since it last started talking, to tell its own voice from the user's.
    private var saying = ""
    /// The sentences handed to the voice and not yet finished.
    private var queued: Set<ObjectIdentifier> = []
    /// Sentences that were cut off are kept a while, so a late word about one of them cannot be taken for a new one.
    private var retired: [AVSpeechUtterance] = []
    private var live: [AVSpeechUtterance] = []
    /// After being talked over: how many words at the start of what was heard were OMNIS's own.
    private var ownWords = 0
    /// After being talked over: how far into the sound OMNIS's own voice could still be heard.
    private var ownUntil: Double?
    private var reconfigurations = 0
    private var voice: AVSpeechSynthesisVoice?
    private var wanted: AVAudioFormat?
    private(set) var echoCancelling = false
    /// Set while OMNIS itself changes how the microphone is used, so that is not taken for new headphones.
    private var reconfiguring = false
    private(set) var isRunning = false
    /// Goes up each time listening is started or stopped, so that work left
    /// over from an earlier start can tell it is no longer wanted.
    private var session = 0
    private var starting = false
    /// How many seconds of sound have been handed to the recogniser. Written from the audio thread.
    private let fed = FedClock()
    private var speakTimeout: Task<Void, Never>?
    private var deviceWatch: NSObjectProtocol?
    /// Called when the microphone changes (headphones in or out), so listening can be started again.
    var onDeviceChange: (() -> Void)?

    private final class FedClock: @unchecked Sendable {
        private let lock = NSLock()
        private var seconds = 0.0
        func add(_ more: Double) { lock.withLock { seconds += more } }
        func reset() { lock.withLock { seconds = 0 } }
        var now: Double { lock.withLock { seconds } }
    }
    /// A pause this long means the speaker has finished.
    static let pauseSeconds = 0.8
    /// How much longer the recogniser is given to settle on its final wording.
    static let settleSeconds = 0.5

    override init() {
        super.init()
        synthesizer.delegate = self
    }

    /// The best English female voice installed, preferring the higher-quality downloads.
    static func bestVoice() -> AVSpeechSynthesisVoice? {
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") && $0.gender == .female }
        return english.max { first, second in
            if first.quality.rawValue != second.quality.rawValue { return first.quality.rawValue < second.quality.rawValue }
            // Between equals, the user's own region, then American English.
            let home = Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
            func rank(_ voice: AVSpeechSynthesisVoice) -> Int { voice.language == home ? 2 : voice.language == "en-US" ? 1 : 0 }
            return rank(first) < rank(second)
        }
    }

    static func voiceDescription() -> String {
        guard let voice = bestVoice() else { return "No English voice is installed" }
        switch voice.quality {
        case .premium: return "\(voice.name) (premium)"
        case .enhanced: return "\(voice.name) (enhanced)"
        default: return "\(voice.name) (basic quality)"
        }
    }

    // MARK: Listening

    func start() async throws {
        guard !isRunning, !starting else { return }
        starting = true
        session += 1
        let mine = session
        defer { if mine == session { starting = false } }
        // After every wait: was listening switched off, or started again, in the meantime?
        func stillWanted() throws { if mine != session { throw CancellationError() } }
        guard await AVCaptureDevice.requestAccess(for: .audio) else { throw VoiceProblem.noMicrophone }
        try stillWanted()
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .timeIndexedProgressiveTranscription)
        switch await AssetInventory.status(forModules: [transcriber]) {
        case .unsupported: throw VoiceProblem.notSupported
        case .installed: break
        default:
            // Apple's speech model for English, downloaded by macOS the first time.
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                try await request.downloadAndInstall()
            }
        }
        try stillWanted()
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let context = AnalysisContext()
        context.contextualStrings[.general] = ["OMNIS", "Hey OMNIS"]
        try? await analyzer.setContext(context)
        guard let wanted = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]) else { throw VoiceProblem.notSupported }
        try stillWanted()

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed = continuation
        self.analyzer = analyzer
        self.wanted = wanted
        voice = Self.bestVoice()
        buffer = UtteranceBuffer()
        soundTime = 0
        fed.reset()
        echoCancelling = false
        do {
            try startAudio(cancelling: false)
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Only this start's own things are undone: a newer start may already be using the microphone.
            if mine == session { teardown() } else { continuation.finish() }
            if error is VoiceProblem { throw error }
            throw VoiceProblem.couldNotStart(error.localizedDescription)
        }
        // Switched off, or started afresh, while this one was starting. `stop` has already let go of
        // the microphone; what is left belongs to this start alone.
        guard mine == session else {
            continuation.finish()
            await analyzer.cancelAndFinishNow()
            throw CancellationError()
        }
        isRunning = true
        deviceWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main) { [weak self] note in
            let from = note.object as AnyObject?
            Task { @MainActor in
                // Only the engine in use now counts, and not a change OMNIS is making itself.
                guard let self, self.isRunning, mine == self.session, !self.reconfiguring, from === self.audio else { return }
                self.onDeviceChange?()
            }
        }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds, end = result.range.end.seconds
                    let final = result.isFinal
                    // Each word with the moment it was said, so OMNIS's own voice can be told from the user's.
                    let words: [(text: String, at: Double?)] = result.text.runs.map { run in
                        (String(result.text[run.range].characters), run.audioTimeRange?.start.seconds)
                    }
                    await MainActor.run {
                        guard let self, mine == self.session else { return }
                        self.took(words, from: start, to: end, final: final)
                    }
                }
            } catch {
                await MainActor.run {
                    // Only a failure of the listening that is still wanted is worth reporting.
                    guard let self, mine == self.session, self.isRunning else { return }
                    self.onProblem?("Listening stopped: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Turns what the microphone gives into what the recogniser wants. The
    /// microphone's own form is read from the sound itself, because it changes
    /// with the device: built-in, AirPods, and echo cancelling all differ.
    private final class Feeder: @unchecked Sendable {
        private let wanted: AVAudioFormat
        private let feed: AsyncStream<AnalyzerInput>.Continuation
        private let fed: FedClock
        private var converter: AVAudioConverter?
        private var from: AVAudioFormat?

        init(wanted: AVAudioFormat, feed: AsyncStream<AnalyzerInput>.Continuation, fed: FedClock) {
            self.wanted = wanted
            self.feed = feed
            self.fed = fed
        }

        /// Called on the audio thread, by one tap at a time. Returns how loud the sound was.
        func take(_ buffer: AVAudioPCMBuffer) -> Double {
            let native = buffer.format
            guard native.sampleRate > 0, native.channelCount > 0, buffer.frameLength > 0 else { return 0 }
            var level = 0.0
            if let samples = buffer.floatChannelData?[0] {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                level = min(1, Double((sum / Float(buffer.frameLength)).squareRoot()) * 6)
            }
            if converter == nil || from != native {
                converter = AVAudioConverter(from: native, to: wanted)
                // Some microphones give several channels at once; the first is the voice.
                if native.channelCount > 1 { converter?.channelMap = Array(repeating: 0, count: Int(wanted.channelCount)) }
                from = native
            }
            let ratio = wanted.sampleRate / native.sampleRate
            guard let converter, let converted = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else {
                return level
            }
            var handed = false
            var failure: NSError?
            converter.convert(to: converted, error: &failure) { _, status in
                if handed {
                    status.pointee = .noDataNow
                    return nil
                }
                handed = true
                status.pointee = .haveData
                return buffer
            }
            if failure == nil, converted.frameLength > 0 {
                feed.yield(AnalyzerInput(buffer: converted))
                fed.add(Double(converted.frameLength) / wanted.sampleRate)
            }
            return level
        }
    }

    /// Runs one of Apple's audio calls. A failure they report by raising an
    /// exception comes back as an ordinary error instead.
    private func guarded(_ work: () throws -> Void) throws {
        var thrown: Error?
        let raised = OmnisCatch {
            do { try work() } catch { thrown = error }
        }
        if let raised { throw VoiceProblem.couldNotStart(raised.reason ?? raised.name.rawValue) }
        if let thrown { throw thrown }
    }

    /// Lets go of the microphone. Nothing here can fail in a way that matters.
    private func stopAudio() {
        let old = audio
        _ = OmnisCatch {
            old.inputNode.removeTap(onBus: 0)
            old.stop()
        }
    }

    /// Starts listening on the microphone as it now is, with or without echo cancelling.
    private func startAudio(cancelling: Bool) throws {
        guard let wanted, let continuation = feed else { throw VoiceProblem.couldNotStart("listening was not set up") }
        stopAudio()
        // A new engine, so nothing is remembered of a microphone that has since changed.
        let fresh = AVAudioEngine()
        audio = fresh
        let feeder = Feeder(wanted: wanted, feed: continuation, fed: fed)
        try guarded {
            let input = fresh.inputNode
            if cancelling {
                try input.setVoiceProcessingEnabled(true)
                input.voiceProcessingOtherAudioDuckingConfiguration =
                    AVAudioVoiceProcessingOtherAudioDuckingConfiguration(enableAdvancedDucking: false, duckingLevel: .min)
            }
            guard input.outputFormat(forBus: 0).sampleRate > 0 else { throw VoiceProblem.couldNotStart("no microphone was found") }
            // No form is asked for: the tap takes whatever the microphone gives.
            input.installTap(onBus: 0, bufferSize: 4096, format: nil) { [weak self] buffer, _ in
                let level = feeder.take(buffer)
                Task { @MainActor [weak self] in
                    guard let self, !self.speaking else { return }
                    self.onLevel?(level)
                }
            }
            fresh.prepare()
            try fresh.start()
        }
    }

    /// Turns the Mac's echo cancelling on or off. With it on, the microphone
    /// hears much less of what the speakers are playing, so OMNIS can keep
    /// listening while it talks. It is on only during a conversation, because
    /// macOS turns other sound down a little while it is.
    func setEchoCancelling(_ on: Bool) {
        guard isRunning, on != echoCancelling else { return }
        reconfiguring = true
        reconfigurations += 1
        let change = reconfigurations
        let mine = session
        do {
            try startAudio(cancelling: on)
            echoCancelling = on
            trace?("echo cancelling \(on ? "on" : "off"), microphone \(audio.inputNode.outputFormat(forBus: 0))")
        } catch {
            trace?("echo cancelling could not be turned \(on ? "on" : "off"): \(error.localizedDescription)")
            // Back to plain listening, which is what worked before.
            echoCancelling = false
            do { try startAudio(cancelling: false) } catch {
                reconfiguring = false
                onProblem?("Listening stopped: \(error.localizedDescription)")
                return
            }
        }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            // A later change is still settling: that one clears the flag.
            guard let self, mine == self.session, change == self.reconfigurations else { return }
            self.reconfiguring = false
        }
    }

    func stop() {
        // Also stops a start that is still under way.
        session += 1
        starting = false
        isRunning = false
        teardown()
        hush()
    }

    private func teardown() {
        if let deviceWatch { NotificationCenter.default.removeObserver(deviceWatch) }
        deviceWatch = nil
        pauseTask?.cancel()
        resultsTask?.cancel()
        resultsTask = nil
        stopAudio()
        echoCancelling = false
        reconfiguring = false
        feed?.finish()
        feed = nil
        let old = analyzer
        analyzer = nil
        Task { await old?.cancelAndFinishNow() }
        buffer = UtteranceBuffer()
    }

    /// Forgets anything heard so far, so the next utterance starts clean.
    func cut() {
        ownWords = 0
        ownUntil = nil
        pauseTask?.cancel()
        buffer.cut(upTo: soundTime)
    }

    private func took(_ words: [(text: String, at: Double?)], from start: Double, to end: Double, final: Bool) {
        guard isRunning, start.isFinite, end.isFinite else { return }
        soundTime = max(soundTime, end)
        var text = words.map(\.text).joined()
        // After being talked over, only the user's words are kept from what overlapped with OMNIS's voice.
        if let ownUntil, !speaking { text = VoiceEcho.usersWords(words, speaking: saying, ownUntil: ownUntil) }
        if speaking {
            // OMNIS does not listen to itself. But someone talking over it is heard, where that is allowed.
            guard allowsInterruption else { return }
            buffer.take(text, start: start, end: end, final: final)
            guard VoiceEcho.isInterruption(heard: buffer.current, speaking: saying) else {
                trace?("own voice heard: \(buffer.current.suffix(60))")
                return
            }
            trace?("talked over: \(buffer.current.suffix(60))")
            // Its own voice stops at once. What was heard is kept, less its own words: it is the start of what the user is saying.
            silence()
            if words.contains(where: { $0.at != nil }) {
                // The room goes quiet a moment after the voice is stopped. Words up to then are sifted one by one.
                let until = fed.now + 0.25
                ownUntil = until
                buffer.cut(upTo: start)
                buffer.take(VoiceEcho.usersWords(words, speaking: saying, ownUntil: until), start: start, end: end, final: final)
            } else {
                // No times came with the words: its own words at the start are left out instead.
                ownWords = VoiceEcho.ownWords(atStartOf: buffer.current, speaking: saying)
            }
            onBargeIn?()
        } else {
            buffer.take(text, start: start, end: end, final: final)
        }
        let current = VoiceEcho.dropping(ownWords, from: buffer.current)
        guard !current.isEmpty else { return }
        onPartial?(current)
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pauseSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning, !self.speaking else { return }
            // The settled wording is the accurate one, so it is waited for a little longer.
            if !self.buffer.isSettled {
                try? await Task.sleep(nanoseconds: UInt64(Self.settleSeconds * 1_000_000_000))
                guard !Task.isCancelled, self.isRunning, !self.speaking else { return }
            }
            let said = VoiceEcho.dropping(self.ownWords, from: self.buffer.current)
            self.cut()
            if !said.isEmpty { self.onUtterance?(said) }
        }
    }

    // MARK: Speaking

    /// Says the words. Called again while still talking, the new words follow on.
    func speak(_ words: String) {
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = voice ?? Self.bestVoice()
        utterance.rate = min(AVSpeechUtteranceMaximumSpeechRate, AVSpeechUtteranceDefaultSpeechRate * Float(speed))
        if !speaking {
            speaking = true
            saying = ""
            cut()
        }
        saying += " " + words
        queued.insert(ObjectIdentifier(utterance))
        live.append(utterance)
        synthesizer.speak(utterance)
        // If the voice never reports that it finished, the conversation must not wait for ever.
        speakTimeout?.cancel()
        let longest = 20 + Double(saying.count) / 8
        speakTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(longest * 1_000_000_000))
            guard !Task.isCancelled, let self, self.speaking else { return }
            self.retire()
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finishedSpeaking()
        }
    }

    private func finishedSpeaking() {
        guard speaking else { return }
        speakTimeout?.cancel()
        speaking = false
        retire()
        // From here only speech that begins after this moment is believed.
        // The end of OMNIS's own voice may still be on its way through the recogniser.
        pauseTask?.cancel()
        ownWords = 0
        ownUntil = nil
        buffer.cut(upTo: fed.now + 0.3, afterOwnVoice: true)
        onLevel?(0)
        onSpeechFinished?()
    }

    /// Stops the voice and forgets what was waiting to be said. Nothing heard is thrown away.
    private func retire() {
        queued.removeAll()
        retired = Array((retired + live).suffix(60))
        live.removeAll()
    }

    private func silence() {
        speakTimeout?.cancel()
        speaking = false
        retire()
        synthesizer.stopSpeaking(at: .immediate)
        onLevel?(0)
    }

    /// Stops speaking at once. Nothing is reported as finished.
    func hush() {
        guard speaking else { return }
        silence()
        pauseTask?.cancel()
        ownWords = 0
        ownUntil = nil
        buffer.cut(upTo: fed.now + 0.3, afterOwnVoice: true)
    }

    func chime() {
        NSSound(named: "Tink")?.play()
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        // One pulse a word, longer words a little bigger.
        let size = min(1.0, 0.45 + Double(characterRange.length) * 0.06)
        Task { @MainActor [weak self] in self?.onLevel?(size) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        Task { @MainActor [weak self] in
            // One that was cut off earlier is not counted.
            guard let self, self.queued.remove(id) != nil, self.queued.isEmpty else { return }
            // A moment for the room to go quiet. If more is handed over meanwhile, it carries on talking.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard self.queued.isEmpty else { return }
            self.finishedSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let id = ObjectIdentifier(utterance)
        // Cut off by the system rather than by OMNIS: treated as finished, so nothing waits on it.
        Task { @MainActor [weak self] in
            guard let self, self.queued.remove(id) != nil, self.queued.isEmpty else { return }
            self.finishedSpeaking()
        }
    }

    /// A soft sound for the end of a conversation, so it is clear OMNIS has stopped listening.
    func closingChime() {
        NSSound(named: "Bottle")?.play()
    }
}
