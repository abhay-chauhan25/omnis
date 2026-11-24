import AppKit
import AVFoundation
import OmnisCore
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
    var onProblem: ((String) -> Void)?

    private let audio = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var feed: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var buffer = UtteranceBuffer()
    /// How far into the sound the recogniser has got.
    private var soundTime = 0.0
    private let synthesizer = AVSpeechSynthesizer()
    private var speaking = false
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
    static let pauseSeconds = 1.1

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
        let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), preset: .progressiveTranscription)
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

        let input = audio.inputNode
        let native = input.outputFormat(forBus: 0)
        guard native.sampleRate > 0, let converter = AVAudioConverter(from: native, to: wanted) else {
            throw VoiceProblem.couldNotStart("no microphone was found")
        }
        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        feed = continuation
        self.analyzer = analyzer
        buffer = UtteranceBuffer()
        soundTime = 0
        fed.reset()
        let fed = self.fed

        input.installTap(onBus: 0, bufferSize: 4096, format: native) { [weak self] buffer, _ in
            // Loudness, for the picture on screen.
            var level = 0.0
            if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                var sum: Float = 0
                for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
                level = min(1, Double((sum / Float(buffer.frameLength)).squareRoot()) * 6)
            }
            let ratio = wanted.sampleRate / native.sampleRate
            guard let converted = AVAudioPCMBuffer(pcmFormat: wanted, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 32) else { return }
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
                continuation.yield(AnalyzerInput(buffer: converted))
                fed.add(Double(converted.frameLength) / wanted.sampleRate)
            }
            Task { @MainActor [weak self] in
                guard let self, !self.speaking else { return }
                self.onLevel?(level)
            }
        }
        do {
            audio.prepare()
            try audio.start()
            try await analyzer.start(inputSequence: stream)
        } catch {
            // Only this start's own things are undone: a newer start may already be using the microphone.
            if mine == session { teardown() } else { continuation.finish() }
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
        deviceWatch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: audio, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isRunning, mine == self.session else { return }
                self.onDeviceChange?()
            }
        }
        resultsTask = Task { [weak self] in
            do {
                for try await result in transcriber.results {
                    let start = result.range.start.seconds, end = result.range.end.seconds
                    let text = String(result.text.characters), final = result.isFinal
                    await MainActor.run {
                        guard let self, mine == self.session else { return }
                        self.took(text, from: start, to: end, final: final)
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
        audio.inputNode.removeTap(onBus: 0)
        audio.stop()
        feed?.finish()
        feed = nil
        let old = analyzer
        analyzer = nil
        Task { await old?.cancelAndFinishNow() }
        buffer = UtteranceBuffer()
    }

    /// Forgets anything heard so far, so the next utterance starts clean.
    func cut() {
        pauseTask?.cancel()
        buffer.cut(upTo: soundTime)
    }

    private func took(_ text: String, from start: Double, to end: Double, final: Bool) {
        guard isRunning, start.isFinite, end.isFinite else { return }
        soundTime = max(soundTime, end)
        // OMNIS does not listen to itself.
        guard !speaking else { return }
        buffer.take(text, start: start, end: end, final: final)
        let current = buffer.current
        guard !current.isEmpty else { return }
        onPartial?(current)
        pauseTask?.cancel()
        pauseTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.pauseSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.isRunning, !self.speaking else { return }
            // The settled wording is the accurate one, so it is waited for a little longer.
            if !self.buffer.isSettled {
                try? await Task.sleep(nanoseconds: 900_000_000)
                guard !Task.isCancelled, self.isRunning, !self.speaking else { return }
            }
            let said = self.buffer.current
            self.cut()
            if !said.isEmpty { self.onUtterance?(said) }
        }
    }

    // MARK: Speaking

    func speak(_ words: String) {
        let utterance = AVSpeechUtterance(string: words)
        utterance.voice = Self.bestVoice()
        speaking = true
        cut()
        synthesizer.speak(utterance)
        // If the voice never reports that it finished, the conversation must not wait for ever.
        speakTimeout?.cancel()
        speakTimeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64((20 + Double(words.count) / 8) * 1_000_000_000))
            guard !Task.isCancelled, let self, self.speaking else { return }
            self.synthesizer.stopSpeaking(at: .immediate)
            self.finishedSpeaking()
        }
    }

    private func finishedSpeaking() {
        guard speaking else { return }
        speakTimeout?.cancel()
        speaking = false
        // From here only speech that begins after this moment is believed.
        // The end of OMNIS's own voice may still be on its way through the recogniser.
        pauseTask?.cancel()
        buffer.cut(upTo: fed.now + 0.3, afterOwnVoice: true)
        onLevel?(0)
        onSpeechFinished?()
    }

    /// Stops speaking at once. Nothing is reported as finished.
    func hush() {
        guard speaking else { return }
        speakTimeout?.cancel()
        speaking = false
        synthesizer.stopSpeaking(at: .immediate)
        pauseTask?.cancel()
        buffer.cut(upTo: fed.now + 0.3, afterOwnVoice: true)
        onLevel?(0)
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
        Task { @MainActor [weak self] in
            // A moment for the room to go quiet.
            try? await Task.sleep(nanoseconds: 250_000_000)
            self?.finishedSpeaking()
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        // Cut off by the system rather than by OMNIS: treated as finished, so nothing waits on it.
        Task { @MainActor [weak self] in self?.finishedSpeaking() }
    }
}
