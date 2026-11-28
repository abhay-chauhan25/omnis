import Foundation

/// How to start the speech helper: OMNIS's own voice, and its second check on the wake phrase.
public struct SpeechHelperConfig: Sendable, Equatable {
    public var python: URL
    public var backendDirectory: URL
    public var models: URL

    public init(python: URL, backendDirectory: URL, models: URL) {
        self.python = python
        self.backendDirectory = backendDirectory
        self.models = models
    }
}

/// A stretch of sound made by the helper, ready to be played.
public struct SpokenSound: Equatable, Sendable {
    public var samples: [Int16]
    public var rate: Double

    public init(samples: [Int16], rate: Double) {
        self.samples = samples
        self.rate = rate
    }
}

public enum SpeechHelperError: Error, Equatable, LocalizedError {
    case notRunning
    case stopped
    case tookTooLong
    case helper(String)

    public var errorDescription: String? {
        switch self {
        case .notRunning: return "The speech helper is not running."
        case .stopped: return "The speech helper stopped."
        case .tookTooLong: return "The speech helper took too long."
        case .helper(let why): return "The speech helper reported a problem: \(why)"
        }
    }
}

/// What is said to the helper and what it says back, with nothing in it that needs a running program.
public enum SpeechWire {
    public enum Reply: Equatable, Sendable {
        case hello
        case audio(id: Int, SpokenSound)
        case done(id: Int)
        case heard(id: Int, text: String)
        case failed(id: Int?, message: String)
    }

    /// The most sound one reply may carry: a minute at the voice's rate.
    static let maxSoundBytes = 24_000 * 2 * 60

    private static func line(_ object: [String: Any]) -> Data {
        var data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data("{}".utf8)
        data.append(0x0A)
        return data
    }

    public static func say(id: Int, text: String, voice: String, speed: Double) -> Data {
        line(["id": id, "op": "say", "text": text, "voice": voice, "speed": speed])
    }

    public static func hear(id: Int, samples: [Int16]) -> Data {
        let bytes = samples.withUnsafeBufferPointer { pointer in
            Data(buffer: UnsafeBufferPointer(start: pointer.baseAddress, count: pointer.count))
        }
        return line(["id": id, "op": "hear", "rate": RecentSound.rate, "pcm": bytes.base64EncodedString()])
    }

    public static func warm(_ what: String) -> Data { line(["op": "warm", "what": what]) }
    public static let cancel = line(["op": "cancel"])

    /// Reads one line from the helper. Nil for anything that is not a reply OMNIS knows.
    public static func reply(_ line: Data) -> Reply? {
        guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
              let type = object["type"] as? String else { return nil }
        let id = object["id"] as? Int
        switch type {
        case "hello":
            return .hello
        case "audio":
            guard let id, let rate = object["rate"] as? Double, (8_000...48_000).contains(rate),
                  let encoded = object["pcm"] as? String, let bytes = Data(base64Encoded: encoded),
                  bytes.count <= maxSoundBytes else { return nil }
            let count = bytes.count / 2
            var samples = [Int16](repeating: 0, count: count)
            samples.withUnsafeMutableBytes { target in
                bytes.prefix(count * 2).withUnsafeBytes { source in target.copyMemory(from: source) }
            }
            return .audio(id: id, SpokenSound(samples: samples, rate: rate))
        case "done":
            return id.map { .done(id: $0) }
        case "heard":
            guard let id, let text = object["text"] as? String else { return nil }
            return .heard(id: id, text: String(text.prefix(2_000)))
        case "error":
            return .failed(id: id, message: String((object["message"] as? String ?? "unknown").prefix(300)))
        default:
            return nil
        }
    }
}

/// The last few seconds the microphone heard, held in memory only.
///
/// It exists so a second listener can check whether the wake phrase was said.
/// It is never written to disk, and it is emptied when listening stops.
public final class RecentSound: @unchecked Sendable {
    public static let rate = 16_000
    public static let seconds = 15

    private let lock = NSLock()
    private var ring = [Int16](repeating: 0, count: RecentSound.rate * RecentSound.seconds)
    private var next = 0
    private var filled = 0

    public init() {}

    /// Adds sound at any rate; it is kept at 16 kHz.
    public func append(_ samples: UnsafeBufferPointer<Float>, rate: Double) {
        guard rate > 0, !samples.isEmpty else { return }
        let step = rate / Double(Self.rate)
        lock.withLock {
            var position = 0.0
            while Int(position) < samples.count {
                // Each kept sample is the average of the ones it stands for, which keeps a faster
                // microphone's higher sounds from turning into noise.
                let from = Int(position), to = min(samples.count, max(from + 1, Int(position + step)))
                var sum: Float = 0
                for index in from..<to { sum += samples[index] }
                let value = max(-1, min(1, sum / Float(to - from)))
                ring[next] = Int16(value * 32_767)
                next = (next + 1) % ring.count
                filled = min(ring.count, filled + 1)
                position += step
            }
        }
    }

    public func append(_ samples: [Float], rate: Double) {
        samples.withUnsafeBufferPointer { append($0, rate: rate) }
    }

    /// The newest sound, at most `seconds` long, oldest first.
    public func last(seconds: Double) -> [Int16] {
        lock.withLock {
            let wanted = min(filled, max(0, Int(seconds * Double(Self.rate))))
            guard wanted > 0 else { return [] }
            let start = (next - wanted + ring.count) % ring.count
            if start + wanted <= ring.count { return Array(ring[start..<start + wanted]) }
            return Array(ring[start...]) + Array(ring[..<(wanted - (ring.count - start))])
        }
    }

    public func clear() {
        lock.withLock {
            for index in ring.indices { ring[index] = 0 }
            next = 0
            filled = 0
        }
    }
}

/// Runs the speech helper and talks to it. The helper is a separate program on
/// this Mac. It is told to work offline and loads only files already on disk,
/// though nothing here could stop it using the network if its code were changed.
/// Sound goes to it and comes back over a pipe and is kept nowhere.
public final class SpeechHelper: @unchecked Sendable {
    public typealias SoundHandler = @Sendable (Result<SpokenSound?, SpeechHelperError>) -> Void

    private let config: SpeechHelperConfig
    private let lock = NSLock()
    private var process: Process?
    private var input: FileHandle?
    private var pendingBytes = Data()
    private var nextID = 0
    private var speaking: [Int: SoundHandler] = [:]
    private var hearing: [Int: CheckedContinuation<String, Error>] = [:]

    public init(config: SpeechHelperConfig) {
        self.config = config
    }

    public var isRunning: Bool { lock.withLock { process?.isRunning == true } }

    /// Starts the helper if it is not already running.
    public func start() throws {
        // A helper that has died without yet being noticed: what waited on it is told so before a new one starts.
        let died = lock.withLock { () -> Bool in
            guard let old = process, !old.isRunning else { return false }
            process = nil
            input = nil
            return true
        }
        if died { failEverything(.stopped) }
        try lock.withLock {
            guard process?.isRunning != true else { return }
            let made = Process()
            made.executableURL = config.python
            made.arguments = ["-m", "omnis_speech", "--models", config.models.path]
            made.currentDirectoryURL = config.backendDirectory
            // Only what the helper needs. Nothing of the user's environment is handed on.
            made.environment = ["PATH": "/usr/bin:/bin", "HOME": NSHomeDirectory(), "HF_HUB_OFFLINE": "1",
                                "PYTHONDONTWRITEBYTECODE": "1"]
            let toHelper = Pipe(), fromHelper = Pipe()
            made.standardInput = toHelper
            made.standardOutput = fromHelper
            made.standardError = FileHandle.nullDevice
            fromHelper.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                if data.isEmpty {
                    handle.readabilityHandler = nil
                    self?.ended(made)
                } else {
                    self?.received(data, from: made)
                }
            }
            do { try made.run() } catch {
                fromHelper.fileHandleForReading.readabilityHandler = nil
                throw SpeechHelperError.helper(error.localizedDescription)
            }
            process = made
            input = toHelper.fileHandleForWriting
            pendingBytes = Data()
        }
    }

    public func stop() {
        let (old, handle) = lock.withLock { () -> (Process?, FileHandle?) in
            defer { process = nil; input = nil }
            return (process, input)
        }
        try? handle?.close()
        if old?.isRunning == true { old?.terminate() }
        failEverything(.stopped)
    }

    private func ended(_ which: Process) {
        let current = lock.withLock { () -> Bool in
            guard process === which else { return false }
            process = nil
            input = nil
            return true
        }
        if current { failEverything(.stopped) }
    }

    private func failEverything(_ why: SpeechHelperError) {
        let (sounds, checks) = lock.withLock { () -> ([SoundHandler], [CheckedContinuation<String, Error>]) in
            defer { speaking.removeAll(); hearing.removeAll() }
            return (Array(speaking.values), Array(hearing.values))
        }
        for handler in sounds { handler(.failure(why)) }
        for check in checks { check.resume(throwing: why) }
    }

    private func send(_ data: Data) -> Bool {
        guard let handle = lock.withLock({ process?.isRunning == true ? input : nil }) else { return false }
        do {
            try handle.write(contentsOf: data)
            return true
        } catch {
            return false
        }
    }

    private func received(_ data: Data, from which: Process) {
        var lines: [Data] = []
        lock.withLock {
            guard process === which else { return }
            pendingBytes.append(data)
            while let end = pendingBytes.firstIndex(of: 0x0A) {
                lines.append(pendingBytes.subdata(in: pendingBytes.startIndex..<end))
                pendingBytes.removeSubrange(pendingBytes.startIndex...end)
            }
            // A line that never ends is not a reply.
            if pendingBytes.count > 16 << 20 { pendingBytes = Data() }
        }
        for line in lines {
            guard let reply = SpeechWire.reply(line) else { continue }
            switch reply {
            case .hello:
                break
            case .audio(let id, let sound):
                lock.withLock { speaking[id] }?(.success(sound))
            case .done(let id):
                lock.withLock { speaking.removeValue(forKey: id) }?(.success(nil))
            case .heard(let id, let text):
                lock.withLock { hearing.removeValue(forKey: id) }?.resume(returning: text)
            case .failed(let id, let message):
                guard let id else { continue }
                let (sound, check) = lock.withLock { (speaking.removeValue(forKey: id), hearing.removeValue(forKey: id)) }
                sound?(.failure(.helper(message)))
                check?.resume(throwing: SpeechHelperError.helper(message))
            }
        }
    }

    /// Loads the voice or the listener ahead of time: "voice" or "listener".
    public func warm(_ what: String) {
        _ = send(SpeechWire.warm(what))
    }

    /// Asks for words to be spoken. `sound` is called with each stretch of sound as it is
    /// made, in order, then once with nil when there is no more, or once with what went wrong.
    public func say(_ text: String, voice: String, speed: Double, sound: @escaping SoundHandler) {
        let id = lock.withLock { () -> Int in
            nextID += 1
            speaking[nextID] = sound
            return nextID
        }
        if !send(SpeechWire.say(id: id, text: text, voice: voice, speed: speed)) {
            lock.withLock { speaking.removeValue(forKey: id) }?(.failure(.notRunning))
        }
    }

    /// Drops everything asked for so far. Nothing more is reported for it.
    public func cancel() {
        lock.withLock { speaking.removeAll() }
        _ = send(SpeechWire.cancel)
    }

    /// What the helper's listener makes of a short stretch of sound.
    public func hear(_ samples: [Int16], timeout: Double = 6) async throws -> String {
        let id = lock.withLock { () -> Int in
            nextID += 1
            return nextID
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.withLock { hearing[id] = continuation }
            if !send(SpeechWire.hear(id: id, samples: samples)) {
                lock.withLock { hearing.removeValue(forKey: id) }?.resume(throwing: SpeechHelperError.notRunning)
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [weak self] in
                self?.lock.withLock { self?.hearing.removeValue(forKey: id) }?.resume(throwing: SpeechHelperError.tookTooLong)
            }
        }
    }
}

public extension OmnisPaths {
    /// Where the speech helper's Python environment and models are kept.
    static var speechFolder: URL { supportDirectory.appendingPathComponent("speech", isDirectory: true) }
}
