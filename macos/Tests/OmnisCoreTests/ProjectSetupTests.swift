import Foundation
import Testing
@testable import OmnisCore

@Suite struct ProjectSetupTests {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("omnis-projects-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func plan(_ arguments: [String: String]) throws -> ProjectPlan {
        try ProjectPlan.make(arguments: arguments, root: root, owner: "someone")
    }

    @Test func aPlanNeedsAPlainNameAFreeFolderAndAStatedVisibility() throws {
        let made = try plan(["name": "voyager-notes", "visibility": "Private", "description": "Notes\nfor Voyager"])
        #expect(made == ProjectPlan(name: "voyager-notes", folder: root.appendingPathComponent("voyager-notes", isDirectory: true),
                                    visibility: .private, owner: "someone", summary: "Notes for Voyager"))
        #expect(made.repository == "someone/voyager-notes" && made.warning == nil)
        #expect(made.rows.map(\.label) == ["Folder", "GitHub", "About", "Steps"])
        #expect(made.rows[1].value == "someone/voyager-notes \u{00B7} private")
        #expect(try plan(["name": "site", "visibility": "public"]).warning == "The repository will be public: anyone can see it.")

        // Public or private is never assumed.
        #expect(throws: ProjectError.needsVisibility) { try plan(["name": "x"]) }
        #expect(throws: ProjectError.needsVisibility) { try plan(["name": "x", "visibility": "internal"]) }
        for bad in ["", "..", ".hidden", "-dash", "has space", "a/b", "../escape", "semi;colon", "$(whoami)", "x.git", String(repeating: "a", count: 65)] {
            #expect(throws: ProjectError.badName, "\(bad)") { try plan(["name": bad, "visibility": "private"]) }
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("taken"), withIntermediateDirectories: true)
        #expect(throws: ProjectError.exists("taken")) { try plan(["name": "taken", "visibility": "private"]) }
        #expect(throws: ProjectError.noProjectsFolder("/nonexistent/projects")) {
            try ProjectPlan.make(arguments: ["name": "x", "visibility": "private"], root: URL(fileURLWithPath: "/nonexistent/projects"))
        }
    }

    @Test func theStepsRunInOrderWithFixedArgumentsAndNoShell() async throws {
        let calls = Collected<[String]>()
        let setup = ProjectSetup(git: URL(fileURLWithPath: "/fake/git"), gh: URL(fileURLWithPath: "/fake/gh")) { program, arguments, directory in
            calls.add([program.lastPathComponent, directory?.lastPathComponent ?? "-"] + arguments)
            return CommandResult(status: 0, output: arguments.first == "config" ? "Someone\n" : "")
        }
        let made = try plan(["name": "voyager-notes", "visibility": "private", "description": "Notes; rm -rf ~"])
        let steps = Collected<String>()
        try await setup.perform(made) { steps.add($0) }
        #expect(calls.values == [
            ["git", "-", "config", "user.name"],
            ["git", "-", "config", "user.email"],
            ["git", "voyager-notes", "init", "-b", "main"],
            ["git", "voyager-notes", "add", "README.md"],
            ["git", "voyager-notes", "commit", "-m", "Initial commit"],
            // The description travels as one argument: it cannot become a command.
            ["gh", "voyager-notes", "repo", "create", "voyager-notes", "--private", "--source", ".", "--remote", "origin", "--push",
             "--description", "Notes; rm -rf ~"],
        ])
        #expect(steps.values.prefix(2) == ["Checking git", "Creating the folder"] && steps.values.last == "Creating the GitHub repository and pushing")
        #expect(try String(contentsOf: made.folder.appendingPathComponent("README.md"), encoding: .utf8) == "# voyager-notes\n\nNotes; rm -rf ~\n")
    }

    @Test func aFailedStepStopsEverythingAfterItAndSaysWhere() async throws {
        let calls = Collected<String>()
        let setup = ProjectSetup(git: URL(fileURLWithPath: "/fake/git"), gh: URL(fileURLWithPath: "/fake/gh")) { program, arguments, _ in
            calls.add(arguments.first ?? "")
            return arguments.first == "repo" ? CommandResult(status: 1, output: "line one\nGraphQL: Name already exists on this account")
                : CommandResult(status: 0, output: arguments.first == "config" ? "Someone" : "")
        }
        let made = try plan(["name": "dup", "visibility": "public"])
        await #expect(throws: ProjectError.stepFailed(step: "creating the GitHub repository and pushing",
                                                      why: "line one GraphQL: Name already exists on this account", folderCreated: true)) {
            try await setup.perform(made)
        }
        #expect(calls.values == ["config", "config", "init", "add", "commit", "repo"])
        let message = ProjectError.stepFailed(step: "creating the GitHub repository and pushing", why: "x", folderCreated: true).localizedDescription
        #expect(message.contains("may or may not exist") && message.contains("delete the folder first"))

        // With no git name or email, nothing at all is created.
        let unset = ProjectSetup(git: URL(fileURLWithPath: "/fake/git"), gh: URL(fileURLWithPath: "/fake/gh")) { _, arguments, _ in
            CommandResult(status: arguments.last == "user.email" ? 1 : 0, output: arguments.last == "user.email" ? "" : "Someone")
        }
        let fresh = try plan(["name": "fresh", "visibility": "private"])
        await #expect(throws: ProjectError.noGitIdentity) { try await unset.perform(fresh) }
        #expect(!FileManager.default.fileExists(atPath: fresh.folder.path))
        #expect(FileManager.default.fileExists(atPath: made.folder.path))      // left as it is, not deleted

        // If the folder cannot be made, nothing else is tried.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("late"), withIntermediateDirectories: true)
        let late = ProjectPlan(name: "late", folder: root.appendingPathComponent("late"), visibility: .private)
        let before = calls.values.count
        await #expect(throws: ProjectError.self) { try await setup.perform(late) }
        #expect(calls.values.count == before + 2)       // only the two checks of git's settings ran
        #expect(Array(calls.values.suffix(2)) == ["config", "config"])
    }

    @Test func theSignedInAccountIsReadCarefully() async {
        func owner(_ status: Int32, _ output: String) async -> String {
            await ProjectSetup(git: URL(fileURLWithPath: "/g"), gh: URL(fileURLWithPath: "/gh")) { _, _, _ in
                CommandResult(status: status, output: output)
            }.owner()
        }
        #expect(await owner(0, "someone\n") == "someone")
        #expect(await owner(1, "not logged in") == "")
        #expect(await owner(0, "an error message with spaces") == "")
    }

    @Test func askingForAProjectIsRecognisedAndAPreviewRunsOnce() throws {
        for text in ["set up a project called voyager-notes", "create a new repo for my thesis", "start a project named x",
                     "Setup a new project", "make me a repository for this"] {
            #expect(ProjectIntent.asksToCreate(text), "\(text)")
        }
        for text in ["open my voyager project", "what projects do I have", "summarise this", "private please"] {
            #expect(!ProjectIntent.asksToCreate(text), "\(text)")
        }

        var chat = Conversation()
        do { let got = chat.offersProject(for: "what's on tomorrow"); #expect(!got) }
        do { let got = chat.offersProject(for: "set up a project called notes"); #expect(got) }
        do { let got = chat.offersProject(for: "private"); #expect(got) }            // answering "public or private?"
        do { let got = chat.offersProject(for: "thanks"); #expect(!got) }

        let answer = chat.begin(question: "set up a project called notes")
        let proposal = ProjectProposal(plan: try plan(["name": "notes", "visibility": "private"]))
        chat.add(proposal, to: answer)
        chat.add(ProjectProposal(plan: try plan(["name": "other", "visibility": "private"])), to: answer)
        #expect(chat.messages.last?.projects.count == 1)                              // one per answer
        chat.update(answer) { $0.state = .done }
        #expect(chat.history().last?.content.contains("[Project preview: new project \"notes\" with a private GitHub repository. Status: preview shown, not yet confirmed by the user, NOT created.]") == true)

        do { let got = chat.beginProject(proposal.id); #expect(got == proposal.plan) }
        do { let got = chat.beginProject(proposal.id); #expect(got == nil) }          // a second click does nothing
        do { let got = chat.declineProject(proposal.id); #expect(!got) }
        chat.updateProject(proposal.id) { $0.state = .failed("it stopped") }
        do { let got = chat.beginProject(proposal.id); #expect(got == nil) }          // a failed set-up is not run again
        #expect(chat.history().last?.content.contains("setting it up failed: it stopped") == true)
    }
}
