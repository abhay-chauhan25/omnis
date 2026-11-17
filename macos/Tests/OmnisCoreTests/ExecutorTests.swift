import Foundation
import Testing
@testable import OmnisCore

final class RecordingPerformer: LaunchPerforming, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [LaunchPlan] = []
    var failure: LaunchError?

    var plans: [LaunchPlan] { lock.withLock { recorded } }

    func perform(_ plan: LaunchPlan) async throws {
        lock.withLock { recorded.append(plan) }
        if let failure { throw failure }
    }
}

final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Int32?
    var value: Int32? { lock.withLock { stored } }
    func set(_ new: Int32) { lock.withLock { stored = new } }
}

@Suite struct ExecutorTests {
    @Test func eachKindGetsItsOwnPlan() throws {
        let executor = Executor(registry: sampleRegistry(), performer: RecordingPerformer())
        #expect(try executor.plan(forEntryID: "app:ChatGPT Classic")
            == .openApplication(URL(fileURLWithPath: "/Applications/ChatGPT Classic.app")))
        #expect(try executor.plan(forEntryID: "project:VoyagerAI")
            == .openItem(URL(fileURLWithPath: "/Users/someone/projects/VoyagerAI"), withApplicationBundleID: "com.microsoft.VSCode"))
        #expect(try executor.plan(forEntryID: "launcher:Ghidra")
            == .runExecutable(URL(fileURLWithPath: "/opt/ghidra/ghidraRun"), arguments: [], workingDirectory: URL(fileURLWithPath: "/opt/ghidra/ghidraRun").deletingLastPathComponent()))
    }

    @Test func nothingOutsideTheRegistryCanRun() async {
        let performer = RecordingPerformer()
        let executor = Executor(registry: sampleRegistry(), performer: performer)
        for id in ["launcher:/bin/rm", "app:Terminal", "/bin/sh", "launcher:Ghidra; rm -rf ~", "", "shell:ls"] {
            await #expect(throws: LaunchError.notInRegistry(id)) {
                try await executor.launch(entryID: id)
            }
        }
        #expect(performer.plans.isEmpty)
    }

    @Test func launchPerformsThePlanAndReturnsTheEntry() async throws {
        let performer = RecordingPerformer()
        let executor = Executor(registry: sampleRegistry(), performer: performer)
        let entry = try await executor.launch(entryID: "launcher:Ghidra")
        #expect(entry.name == "Ghidra")
        #expect(performer.plans.count == 1)
    }

    @Test func performerFailureIsPassedOn() async {
        let performer = RecordingPerformer()
        performer.failure = .applicationNotInstalled("com.microsoft.VSCode")
        let executor = Executor(registry: sampleRegistry(), performer: performer)
        await #expect(throws: LaunchError.applicationNotInstalled("com.microsoft.VSCode")) {
            try await executor.launch(entryID: "project:omnis")
        }
    }

    /// Runs a real script whose name and folder are full of shell syntax.
    /// If a shell were involved anywhere, the extra files would appear.
    @Test func shellCharactersInNamesAreNotInterpreted() async throws {
        let scratch = try Scratch()
        let folder = try scratch.folder("dir; touch INJECTED_DIR; $(touch SUBST) `touch TICK` && echo")
        let script = folder.appendingPathComponent("run; touch INJECTED_NAME | $(touch SUBST2) > out.sh")
        try "#!/bin/sh\necho \"$#\" > ran.txt\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)

        let config = RegistryConfig(appRoots: [], projectRoots: [], editor: vsCode,
                                    launchers: [LauncherSpec(name: "Odd; rm -rf ~", path: script.path)])
        let registry = try Registry.load(config: config, home: scratch.url)
        let executor = Executor(registry: registry, performer: SystemLaunchPerformer())
        try await executor.launch(entryID: "launcher:Odd; rm -rf ~")

        let marker = folder.appendingPathComponent("ran.txt")
        #expect(await waitUntil { FileManager.default.fileExists(atPath: marker.path) })
        // The script ran in its own folder with zero arguments.
        #expect(try String(contentsOf: marker, encoding: .utf8) == "0\n")

        let everything = FileManager.default.enumerator(at: scratch.url, includingPropertiesForKeys: nil)?
            .compactMap { ($0 as? URL)?.lastPathComponent } ?? []
        for planted in ["INJECTED_DIR", "INJECTED_NAME", "SUBST", "SUBST2", "TICK", "out.sh"] {
            #expect(!everything.contains(planted))
        }
    }

    @Test func aProgramThatCannotStartIsAnError() async {
        let performer = SystemLaunchPerformer()
        let plan = LaunchPlan.runExecutable(URL(fileURLWithPath: "/definitely/not/here"), arguments: [], workingDirectory: URL(fileURLWithPath: "/tmp"))
        do {
            try await performer.perform(plan)
            Issue.record("expected a failure")
        } catch let error as LaunchError {
            guard case .failed = error else { Issue.record("wrong error: \(error)"); return }
        } catch {
            Issue.record("wrong error type: \(error)")
        }
    }

    @Test func aProgramThatExitsBadlyIsReportedLater() async throws {
        let scratch = try Scratch()
        let script = try scratch.file("fail.sh", contents: "#!/bin/sh\nexit 3\n", executable: true)
        let flag = Flag()
        let performer = SystemLaunchPerformer(onLateFailure: { _, status in flag.set(status) })
        try await performer.perform(.runExecutable(script, arguments: [], workingDirectory: scratch.url))
        #expect(await waitUntil { flag.value != nil })
        #expect(flag.value == 3)
    }

    @Test func missingEditorIsReported() async {
        let performer = SystemLaunchPerformer()
        await #expect(throws: LaunchError.applicationNotInstalled("invalid.omnis.no-such-editor")) {
            try await performer.perform(.openItem(URL(fileURLWithPath: "/tmp"), withApplicationBundleID: "invalid.omnis.no-such-editor"))
        }
    }
}

@Suite struct AuditLogTests {
    @Test func writesOneJSONLinePerActionWithPrivatePermissions() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("logs/audit.log")
        let log = AuditLog(url: file, now: { Date(timeIntervalSince1970: 1_800_000_000) })
        log.record(action: "launch", kind: "project", target: "VoyagerAI", outcome: "ok")
        log.record(action: "ask", outcome: "error", detail: "backend stopped")
        log.flush()

        let lines = try String(contentsOf: file, encoding: .utf8).split(separator: "\n")
        #expect(lines.count == 2)
        let first = try JSONDecoder().decode(AuditLog.Record.self, from: Data(lines[0].utf8))
        #expect(first.action == "launch")
        #expect(first.target == "VoyagerAI")
        #expect(first.outcome == "ok")
        #expect(first.time == "2027-01-15T08:00:00Z")
        let second = try JSONDecoder().decode(AuditLog.Record.self, from: Data(lines[1].utf8))
        #expect(second.target == nil)
        #expect(second.detail == "backend stopped")

        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
    }
}
