import Foundation
import Testing
@testable import OmnisCore

@Suite struct ProjectSessionTests {
    @Test func aSessionStartsWithTheAgreedRulesAndTheBriefCannotBecomeAnOption() {
        let arguments = ProjectSession.arguments(name: "VoyagerAI", brief: "  --dangerously-skip-permissions add a login page ")
        #expect(arguments.first == "--allowedTools")
        let mode = arguments.firstIndex(of: "--permission-mode")!
        #expect(arguments[mode + 1] == "acceptEdits")
        #expect(arguments[(mode + 2)...].prefix(2) == ["--name", "VoyagerAI"])
        // The brief follows "--", so it is always read as the first message.
        #expect(arguments.suffix(2) == ["--", "--dangerously-skip-permissions add a login page"])
        #expect(!arguments.dropLast(1).contains("--dangerously-skip-permissions"))
        #expect(ProjectSession.arguments(name: "x", resume: true).last == "--continue")
        #expect(ProjectSession.arguments(name: "x", brief: "  \n ").last == "x")

        let safe = ProjectSession.safeCommands
        #expect(safe.contains("Bash(git status)") && safe.contains("Bash(git commit *)") && safe.contains("Bash(swift test *)"))
        // Never without asking: pushing, installing, deleting, fetching.
        for word in ["push", "install", "rm", "curl", "sudo", "reset", "checkout", "clean", "publish"] {
            #expect(!safe.contains { $0.contains(" \(word)") || $0.contains("(\(word)") }, "\(word)")
        }

        let launch = ProjectSession.launch(claude: URL(fileURLWithPath: "/Users/me/.local/bin/claude"), arguments: ["--name", "a b; rm -rf ~"])
        #expect(launch.executable == "/bin/zsh")
        #expect(launch.arguments == ["-l", "-c", "exec \"$0\" \"$@\"", "/Users/me/.local/bin/claude", "--name", "a b; rm -rf ~"])
    }

    @Test func aProjectsSessionFolderIsFoundTheWayClaudeCodeNamesIt() {
        let home = URL(fileURLWithPath: "/Users/me")
        #expect(ProjectSession.transcriptFolder(for: URL(fileURLWithPath: "/Users/me/projects/omnis"), home: home).path
                == "/Users/me/.claude/projects/-Users-me-projects-omnis")
        #expect(ProjectSession.transcriptFolder(for: URL(fileURLWithPath: "/Users/me/my projects/voyager.ai_v2"), home: home).lastPathComponent
                == "-Users-me-my-projects-voyager-ai-v2")
    }

    @Test func aSessionsRecordIsReadIntoPlainSteps() {
        let lines = [
            #"{"type":"ai-title","aiTitle":"Add a login page"}"#,
            #"{"type":"last-prompt","lastPrompt":"add a login page\nwith tests"}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"I'll start with the routes."},{"type":"tool_use","name":"Read","input":{"file_path":"/p/src/routes.py"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"TodoWrite","input":{"todos":[{"content":"Add route","status":"completed"},{"content":"Write tests","status":"in_progress"}]}}]}}"#,
            #"{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"hidden agent work"}}]}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Edit","input":{"file_path":"/p/src/login.py"}},{"type":"tool_use","name":"Bash","input":{"command":"pytest -q","description":"Run the tests"}},{"type":"tool_use","name":"Agent","input":{"description":"Review the form"}},{"type":"tool_use","name":"mcp__x__y","input":{}}]}}"#,
            "not json",
            #"{"type":"user","message":{"content":"ignored"}}"#,
            #"{"type":"assistant","message":{"content":[{"type":"text","text":"Tests pass.\nNext: the form."}]}}"#,
        ]
        let activity = SessionTranscripts.activity(from: Data(lines.joined(separator: "\n").utf8))
        #expect(activity.title == "Add a login page")
        #expect(activity.lastPrompt == "add a login page with tests")
        #expect(activity.steps == ["Read routes.py", "Edited login.py", "Ran: Run the tests", "Started an agent: Review the form", "Used mcp__x__y"])
        #expect(activity.tasks == [.init(text: "Add route", state: "completed"), .init(text: "Write tests", state: "in_progress")])
        #expect(activity.lastText == "Tests pass. Next: the form.")
        #expect(SessionTranscripts.activity(from: Data()).isEmpty)

        let many = (0..<30).map { #"{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"/p/f\#($0).py"}}]}}"# }
        #expect(SessionTranscripts.activity(from: Data(many.joined(separator: "\n").utf8)).steps.first == "Read f22.py")

        let brief = SessionTranscripts.brief(activity, changedFiles: ["M src/login.py", "?? tests/test_login.py"])
        #expect(brief.contains("The user last asked it: add a login page with tests"))
        #expect(brief.contains("- [in_progress] Write tests") && brief.contains("- ?? tests/test_login.py"))
        #expect(SessionTranscripts.brief(nil, changedFiles: []) == "No Claude Code session has been recorded for this project yet.")
    }

    @Test func theLatestSessionOfAProjectIsLoadedFromItsFolder() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-home-\(UUID().uuidString)")
        let project = URL(fileURLWithPath: "/Users/me/projects/demo")
        let folder = ProjectSession.transcriptFolder(for: project, home: home)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        #expect(SessionTranscripts.load(project: project, home: home) == nil)
        try #"{"type":"last-prompt","lastPrompt":"old"}"#.write(to: folder.appendingPathComponent("a.jsonl"), atomically: true, encoding: .utf8)
        let newer = folder.appendingPathComponent("b.jsonl")
        try #"{"type":"last-prompt","lastPrompt":"new"}"#.write(to: newer, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: newer.path)
        try "notes".write(to: folder.appendingPathComponent("c.txt"), atomically: true, encoding: .utf8)
        let loaded = SessionTranscripts.load(project: project, home: home)
        #expect(loaded?.lastPrompt == "new" && loaded?.updated != nil)
    }

    @Test func theAdvisorMayReadOnlyInsideTheProjectAndNotSecrets() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-proj-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("src"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("escape"), withDestinationURL: URL(fileURLWithPath: "/etc"))
        for path in [nil, "", "src/app.py", folder.path, folder.path + "/src/app.py", "README.md"] as [String?] {
            #expect(ProjectFiles.mayRead(path, in: folder), "\(path ?? "nil")")
        }
        for path in ["/etc/hosts", "../other/file", folder.path + "/../x", folder.path + "-other/x", "escape/hosts", ".env", "src/.env.local",
                     "keys/server.pem", "id_rsa", ".git/config", "~/.ssh/id_rsa", "/Users/me/.claude/projects/x"] {
            #expect(!ProjectFiles.mayRead(path, in: folder), "\(path)")
        }
    }

    @Test func changedFilesComeFromGit() async {
        let files = await ProjectFiles.changed(in: URL(fileURLWithPath: "/p"), git: URL(fileURLWithPath: "/git")) { _, arguments, _ in
            #expect(arguments == ["status", "--porcelain"])
            return CommandResult(status: 0, output: " M src/login.py\n?? tests/new.py\nA  docs/a b.md\n")
        }
        #expect(files == ["M src/login.py", "?? tests/new.py", "A docs/a b.md"])
        let none = await ProjectFiles.changed(in: URL(fileURLWithPath: "/p"), git: URL(fileURLWithPath: "/git")) { _, _, _ in
            CommandResult(status: 128, output: "fatal: not a git repository")
        }
        #expect(none.isEmpty)
    }

    @Test func theAdvisorSessionIsReadOnlyByConstruction() {
        var config = ClaudeConfig(executable: URL(fileURLWithPath: "/c"), python: URL(fileURLWithPath: "/p"),
                                  backendDirectory: URL(fileURLWithPath: "/b"), workingDirectory: URL(fileURLWithPath: "/proj"))
        config.profile = .advisor(folder: URL(fileURLWithPath: "/proj"), project: "demo")
        let arguments = config.arguments(model: .sonnet, effort: "medium", systemPrompt: ClaudePrompt.advisor(project: "demo"))
        func value(after flag: String) -> String? { arguments.firstIndex(of: flag).map { arguments[$0 + 1] } }
        #expect(value(after: "--tools") == "Read,Glob,Grep")
        let refused = value(after: "--disallowedTools")?.split(separator: ",").map(String.init) ?? []
        for tool in ["Bash", "Edit", "Write", "WebFetch", "WebSearch", "Task"] { #expect(refused.contains(tool)) }
        #expect(!refused.contains("Read"))
        for file in ["Read(./.env)", "Read(./**/.env.*)", "Read(./**/*.pem)", "Read(./.git/**)"] { #expect(refused.contains(file), "\(file)") }
        #expect(value(after: "--permission-prompt-tool") == "stdio" && value(after: "--setting-sources") == "")
        #expect(arguments.contains("--no-session-persistence") && !arguments.contains("omnis_backend.claude_tools"))
        #expect(config.expects(tool: "Read") && !config.expects(tool: "Bash") && !config.expects(tool: "WebSearch")
                && !config.expects(tool: "mcp__omnis__calendar_events"))
        #expect(ClaudePrompt.advisor(project: "demo").contains("You cannot change files"))
    }
}
