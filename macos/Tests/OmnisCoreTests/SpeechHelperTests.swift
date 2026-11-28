import Foundation
import Testing
@testable import OmnisCore

@Suite struct SpeechWireTests {
    private func object(_ data: Data) -> [String: Any] {
        #expect(data.last == 0x0A)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    @Test func asksForWordsToBeSaid() {
        let sent = object(SpeechWire.say(id: 3, text: "Hello \"there\"\nyou", voice: "am_adam", speed: 1.08))
        #expect(sent["op"] as? String == "say")
        #expect(sent["id"] as? Int == 3)
        #expect(sent["text"] as? String == "Hello \"there\"\nyou")
        #expect(sent["voice"] as? String == "am_adam")
        // One line, whatever the words hold.
        #expect(SpeechWire.say(id: 3, text: "a\nb", voice: "x", speed: 1).filter { $0 == 0x0A }.count == 1)
    }

    @Test func sendsSoundAsSixteenBitSamples() {
        let sent = object(SpeechWire.hear(id: 9, samples: [0, 1, -1, 32_767]))
        #expect(sent["rate"] as? Int == 16_000)
        let bytes = Data(base64Encoded: sent["pcm"] as? String ?? "") ?? Data()
        #expect(Array(bytes) == [0, 0, 1, 0, 0xFF, 0xFF, 0xFF, 0x7F])
    }

    @Test func readsSoundBack() {
        let pcm = Data([1, 0, 0xFF, 0xFF, 7]).base64EncodedString()
        let line = Data(#"{"id":4,"type":"audio","rate":24000,"pcm":"\#(pcm)"}"#.utf8)
        // A stray last byte is not half a sample.
        #expect(SpeechWire.reply(line) == .audio(id: 4, SpokenSound(samples: [1, -1], rate: 24_000)))
    }

    @Test func readsTheOtherReplies() {
        #expect(SpeechWire.reply(Data(#"{"type":"hello","version":1}"#.utf8)) == .hello)
        #expect(SpeechWire.reply(Data(#"{"id":2,"type":"done"}"#.utf8)) == .done(id: 2))
        #expect(SpeechWire.reply(Data(#"{"id":5,"type":"heard","text":"Yo Omi."}"#.utf8)) == .heard(id: 5, text: "Yo Omi."))
        #expect(SpeechWire.reply(Data(#"{"id":5,"type":"error","message":"no"}"#.utf8)) == .failed(id: 5, message: "no"))
    }

    @Test func ignoresWhatItDoesNotKnow() {
        for junk in ["", "hello", "[1]", #"{"type":"audio","id":1,"rate":24000,"pcm":"!!"}"#, #"{"type":"audio","id":1,"rate":1,"pcm":""}"#,
                     #"{"type":"heard","id":1}"#, #"{"type":"done"}"#, #"{"type":"shout","id":1}"#] {
            #expect(SpeechWire.reply(Data(junk.utf8)) == nil, "\(junk)")
        }
    }

    @Test func refusesMoreSoundThanAMinute() {
        let pcm = Data(count: SpeechWire.maxSoundBytes + 2).base64EncodedString()
        #expect(SpeechWire.reply(Data(#"{"id":4,"type":"audio","rate":24000,"pcm":"\#(pcm)"}"#.utf8)) == nil)
    }
}

@Suite struct RecentSoundTests {
    @Test func keepsTheNewestSound() {
        let sound = RecentSound()
        sound.append([Float](repeating: 0.5, count: 16_000), rate: 16_000)
        sound.append([Float](repeating: -0.5, count: 8_000), rate: 16_000)
        let last = sound.last(seconds: 1)
        #expect(last.count == 16_000)
        #expect(last.first! > 16_000 && last.last! < -16_000)
        // Asking for more than was heard gives what there is.
        #expect(sound.last(seconds: 10).count == 24_000)
    }

    @Test func holdsOnlyTheLastFifteenSeconds() {
        let sound = RecentSound()
        for value in 0..<20 { sound.append([Float](repeating: Float(value) / 100, count: 16_000), rate: 16_000) }
        let all = sound.last(seconds: 60)
        #expect(all.count == 15 * 16_000)
        // Oldest first: second 5 at the start, second 19 at the end.
        #expect(all.first == Int16(0.05 * 32_767) && all.last == Int16(Float(19) / 100 * 32_767))
    }

    @Test func bringsAFasterMicrophoneDownToSixteenKilohertz() {
        let sound = RecentSound()
        sound.append([Float](repeating: 0.25, count: 48_000), rate: 48_000)
        let kept = sound.last(seconds: 5)
        #expect(kept.count == 16_000)
        #expect(kept.allSatisfy { $0 == Int16(0.25 * 32_767) })
    }

    @Test func loudSoundIsHeldWithinRange() {
        let sound = RecentSound()
        sound.append([3, -3], rate: 16_000)
        #expect(sound.last(seconds: 1) == [32_767, -32_767])
    }

    @Test func isEmptiedWhenCleared() {
        let sound = RecentSound()
        sound.append([0.5, 0.5], rate: 16_000)
        sound.clear()
        #expect(sound.last(seconds: 1).isEmpty)
    }
}

/// The helper itself, stood in for by a few lines of Python that answer the same way.
@Suite struct SpeechHelperProcessTests {
    private static let python = URL(fileURLWithPath: "/usr/bin/python3")

    private func helper(_ body: String) throws -> (SpeechHelper, URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-speech-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("omnis_speech"), withIntermediateDirectories: true)
        try Data().write(to: folder.appendingPathComponent("omnis_speech/__init__.py"))
        try Data(body.utf8).write(to: folder.appendingPathComponent("omnis_speech/__main__.py"))
        return (SpeechHelper(config: SpeechHelperConfig(python: Self.python, backendDirectory: folder, models: folder)), folder)
    }

    private static let standIn = """
    import base64, json, sys
    print(json.dumps({"type": "hello", "version": 1}), flush=True)
    for line in sys.stdin:
        m = json.loads(line)
        if m.get("op") == "say":
            if m["text"] == "fail":
                print(json.dumps({"id": m["id"], "type": "error", "message": "could not"}), flush=True)
                continue
            for part in m["text"].split("|"):
                pcm = base64.b64encode(bytes([len(part), 0])).decode()
                print(json.dumps({"id": m["id"], "type": "audio", "rate": 24000, "pcm": pcm}), flush=True)
            print(json.dumps({"id": m["id"], "type": "done"}), flush=True)
        elif m.get("op") == "hear":
            n = len(base64.b64decode(m["pcm"])) // 2
            print(json.dumps({"id": m["id"], "type": "heard", "text": "%d samples" % n}), flush=True)
        elif m.get("op") == "quit":
            sys.exit(0)
    """

    private final class Collected: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [Result<SpokenSound?, SpeechHelperError>] = []
        func add(_ item: Result<SpokenSound?, SpeechHelperError>) { lock.withLock { items.append(item) } }
        var all: [Result<SpokenSound?, SpeechHelperError>] { lock.withLock { items } }
        func wait(for count: Int) async {
            for _ in 0..<200 where all.count < count { try? await Task.sleep(nanoseconds: 25_000_000) }
        }
    }

    @Test func saysASentenceAtATimeInOrder() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else { return }
        let (helper, folder) = try helper(Self.standIn)
        defer { helper.stop(); try? FileManager.default.removeItem(at: folder) }
        try helper.start()
        let got = Collected()
        helper.say("a|bb|ccc", voice: "am_adam", speed: 1) { got.add($0) }
        await got.wait(for: 4)
        #expect(got.all == [.success(SpokenSound(samples: [1], rate: 24_000)), .success(SpokenSound(samples: [2], rate: 24_000)),
                            .success(SpokenSound(samples: [3], rate: 24_000)), .success(nil)])
    }

    @Test func hearsAndReportsFailure() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else { return }
        let (helper, folder) = try helper(Self.standIn)
        defer { helper.stop(); try? FileManager.default.removeItem(at: folder) }
        try helper.start()
        #expect(try await helper.hear([1, 2, 3]) == "3 samples")
        let got = Collected()
        helper.say("fail", voice: "am_adam", speed: 1) { got.add($0) }
        await got.wait(for: 1)
        #expect(got.all == [.failure(.helper("could not"))])
    }

    @Test func whatWasCancelledIsNotReported() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else { return }
        let (helper, folder) = try helper(Self.standIn)
        defer { helper.stop(); try? FileManager.default.removeItem(at: folder) }
        try helper.start()
        let got = Collected()
        helper.say("a|b", voice: "am_adam", speed: 1) { got.add($0) }
        helper.cancel()
        // A later request is still answered, and nothing of the earlier one arrives after the cancel.
        #expect(try await helper.hear([1]) == "1 samples")
        #expect(got.all.count <= 3)
    }

    @Test func aHelperThatStopsFailsWhatWasWaiting() async throws {
        guard FileManager.default.isExecutableFile(atPath: Self.python.path) else { return }
        let (helper, folder) = try helper("import sys\nsys.stdin.readline()\n")
        defer { helper.stop(); try? FileManager.default.removeItem(at: folder) }
        try helper.start()
        await #expect(throws: SpeechHelperError.stopped) { _ = try await helper.hear([1, 2]) }
        #expect(!helper.isRunning)
    }

    @Test func aMissingHelperSaysSo() async throws {
        let folder = FileManager.default.temporaryDirectory
        let helper = SpeechHelper(config: SpeechHelperConfig(python: URL(fileURLWithPath: "/nonexistent/python"), backendDirectory: folder, models: folder))
        #expect(throws: SpeechHelperError.self) { try helper.start() }
        await #expect(throws: SpeechHelperError.notRunning) { _ = try await helper.hear([1]) }
    }
}
