import AVFoundation
import OmnisCore
import OmnisObjC

/// Plays the sound OMNIS's own voice is made of, a stretch at a time, one after another.
///
/// It has its own audio engine, apart from the one that listens, so that a
/// change of microphone never interrupts what is being said.
final class OwnVoicePlayer: @unchecked Sendable {
    private var engine: AVAudioEngine?
    private var node: AVAudioPlayerNode?
    private var rate = 0.0
    /// The speakers or headphones changed while something was playing. What was queued will not be heard.
    var onInterrupted: (@Sendable () -> Void)?
    private var watch: NSObjectProtocol?
    /// Development aid: everything happens as usual, but nothing is heard.
    var muted = false
    /// How loud what is being played is, from 0 to 1. Called on the audio thread.
    var onLevel: (@Sendable (Double) -> Void)?

    /// Queues a stretch of sound. `played` is called when it has been heard, or when it was
    /// stopped before it could be. Returns false if the sound could not be queued.
    func schedule(_ sound: SpokenSound, played: @escaping @Sendable () -> Void) -> Bool {
        guard !sound.samples.isEmpty, sound.rate > 0,
              let format = AVAudioFormat(standardFormatWithSampleRate: sound.rate, channels: 1),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(sound.samples.count)),
              let target = buffer.floatChannelData?[0] else { return false }
        for (index, sample) in sound.samples.enumerated() { target[index] = Float(sample) / 32_768 }
        buffer.frameLength = AVAudioFrameCount(sound.samples.count)
        var failed = false
        let raised = OmnisCatch {
            do {
                if self.engine?.isRunning != true || self.rate != sound.rate { try self.begin(format) }
                guard let node = self.node else { failed = true; return }
                node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in played() }
                if !node.isPlaying { node.play() }
            } catch {
                failed = true
            }
        }
        if raised != nil || failed {
            shutDown()
            return false
        }
        return true
    }

    /// A new engine each time, so it always plays through the speakers or headphones as they now are.
    private func begin(_ format: AVAudioFormat) throws {
        shutDown()
        let fresh = AVAudioEngine()
        let player = AVAudioPlayerNode()
        fresh.attach(player)
        fresh.connect(player, to: fresh.mainMixerNode, format: format)
        let report = onLevel
        fresh.mainMixerNode.installTap(onBus: 0, bufferSize: 2048, format: nil) { buffer, _ in
            guard let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
            var sum: Float = 0
            for index in 0..<Int(buffer.frameLength) { sum += samples[index] * samples[index] }
            report?(min(1, Double((sum / Float(buffer.frameLength)).squareRoot()) * 5))
        }
        fresh.mainMixerNode.outputVolume = muted ? 0 : 1
        fresh.prepare()
        try fresh.start()
        engine = fresh
        node = player
        rate = format.sampleRate
        watch = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: fresh, queue: nil) { [weak self] _ in
            self?.onInterrupted?()
        }
    }

    /// Stops what is playing and forgets what was queued. The engine is kept for what is said next.
    func stop() {
        guard let node else { return }
        _ = OmnisCatch { node.stop() }
    }

    /// Lets go of the speakers until something is said again.
    func shutDown() {
        let old = engine, oldNode = node
        if let watch { NotificationCenter.default.removeObserver(watch) }
        watch = nil
        engine = nil
        node = nil
        rate = 0
        _ = OmnisCatch {
            oldNode?.stop()
            old?.mainMixerNode.removeTap(onBus: 0)
            old?.stop()
        }
    }
}
