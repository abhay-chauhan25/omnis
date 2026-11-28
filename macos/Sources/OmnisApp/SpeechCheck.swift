import AVFoundation
import OmnisCore

/// Development aid behind `--check-speech`: proves the helper, the voices and the player work
/// together on this Mac, with the sound turned off, and tries the second listener on sound files.
@MainActor
enum SpeechCheck {
    private final class Count: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func add() { lock.withLock { value += 1 } }
        var now: Int { lock.withLock { value } }
    }

    static func run(files: [URL]) async {
        func say(_ line: String) { print(line); fflush(stdout) }
        guard let config = AppEnvironment.speechConfig() else {
            say("speech check: not set up. Run backend/scripts/setup-speech.sh")
            return
        }
        let helper = SpeechHelper(config: config)
        defer { helper.stop() }
        do { try helper.start() } catch {
            say("speech check: the helper could not start: \(error.localizedDescription)")
            return
        }
        var began = Date()
        func elapsed() -> String { String(format: "%.2f s", Date().timeIntervalSince(began)) }
        // One second of silence: this loads the listener and proves it answers.
        let quiet = (try? await helper.hear([Int16](repeating: 0, count: RecentSound.rate), timeout: 60)) ?? "?"
        say("listener ready after \(elapsed()); silence heard as \"\(quiet)\"")

        let player = OwnVoicePlayer()
        player.muted = true
        defer { player.shutDown() }
        for choice in VoiceChoice.allCases {
            guard let voice = choice.helperVoice else { continue }
            began = Date()
            let made = Count(), played = Count(), finished = Count(), failed = Count()
            var first: String?
            var seconds = 0.0
            let stream = AsyncStream<Result<SpokenSound?, SpeechHelperError>> { continuation in
                helper.say("Oh nice, you've got a pretty light day. There's just the design review at two.", voice: voice, speed: 1) {
                    continuation.yield($0)
                    if case .success(.some) = $0 { return }
                    continuation.finish()
                }
            }
            for await result in stream {
                switch result {
                case .success(let sound?):
                    if first == nil { first = elapsed() }
                    seconds += Double(sound.samples.count) / sound.rate
                    if player.schedule(sound, played: { played.add() }) { made.add() } else { failed.add() }
                case .success(nil): finished.add()
                case .failure(let problem): say("\(choice.title): \(problem.localizedDescription)"); failed.add()
                }
            }
            for _ in 0..<400 where played.now < made.now { try? await Task.sleep(nanoseconds: 50_000_000) }
            say("\(choice.title): first sound after \(first ?? "never"), \(made.now) sentences, \(String(format: "%.1f", seconds)) s of sound, "
                + "\(played.now) played through (muted) by \(elapsed()), \(failed.now) failed")
        }

        for file in files {
            guard let audio = try? AVAudioFile(forReading: file),
                  let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)),
                  (try? audio.read(into: buffer)) != nil, let samples = buffer.floatChannelData?[0] else {
                say("\(file.lastPathComponent): could not be read")
                continue
            }
            let recent = RecentSound()
            recent.append(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength)), rate: audio.processingFormat.sampleRate)
            began = Date()
            let heard = (try? await helper.hear(recent.last(seconds: 15))) ?? "(no answer)"
            let wake = VoicePhrases.afterWake(heard).map { "WAKE, then \"\($0)\"" } ?? "no wake"
            say("\(file.lastPathComponent): \(wake) [second listener wrote \"\(heard)\" in \(elapsed())]")
        }
    }
}
