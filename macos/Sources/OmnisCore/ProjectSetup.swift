import Foundation

/// A new project that has been proposed but not created.
public struct ProjectPlan: Equatable, Sendable {
    public enum Visibility: String, Sendable { case `private`, `public` }

    public let name: String
    /// The folder that will be created. It does not exist yet.
    public let folder: URL
    public let visibility: Visibility
    /// The GitHub account the repository will belong to, if known.
    public let owner: String
    public let summary: String?

    public init(name: String, folder: URL, visibility: Visibility, owner: String = "", summary: String? = nil) {
        self.name = name
        self.folder = folder
        self.visibility = visibility
        self.owner = owner
        self.summary = summary
    }

    /// Builds a plan from what the model asked for. The name must be plain,
    /// the folder must not exist, and whether the repository is public or
    /// private must have been said: it is never assumed.
    public static func make(arguments: [String: String], root: URL, owner: String = "",
                            fileManager: FileManager = .default) throws -> ProjectPlan {
        let name = (arguments["name"] ?? "").trimmingCharacters(in: .whitespaces)
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        guard (1...64).contains(name.count), name.unicodeScalars.allSatisfy(allowed.contains),
              let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              name != ".", name != "..", !name.hasSuffix(".git") else {
            throw ProjectError.badName
        }
        guard let visibility = Visibility(rawValue: (arguments["visibility"] ?? "").lowercased()) else {
            throw ProjectError.needsVisibility
        }
        var isFolder: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isFolder), isFolder.boolValue else {
            throw ProjectError.noProjectsFolder(root.path)
        }
        let folder = root.appendingPathComponent(name, isDirectory: true)
        guard !fileManager.fileExists(atPath: folder.path) else { throw ProjectError.exists(name) }
        let summary = CalendarFormatter.clean(arguments["description"] ?? "")
        return ProjectPlan(name: name, folder: folder, visibility: visibility, owner: owner,
                           summary: summary.isEmpty ? nil : summary)
    }

    public var repository: String { owner.isEmpty ? name : "\(owner)/\(name)" }

    /// What will be done, line by line, for the preview.
    public var rows: [ChangeRow] {
        var rows = [
            ChangeRow("Folder", folder.path.replacingOccurrences(of: FileManager.default.homeDirectoryForCurrentUser.path, with: "~")),
            ChangeRow("GitHub", "\(repository) \u{00B7} \(visibility.rawValue)"),
        ]
        if let summary { rows.append(ChangeRow("About", summary)) }
        rows.append(ChangeRow("Steps", "create the folder with a README \u{2192} start git \u{2192} first commit \u{2192} create the GitHub repository \u{2192} push \u{2192} open in the editor"))
        return rows
    }

    public var warning: String? {
        visibility == .public ? "The repository will be public: anyone can see it." : nil
    }

    /// One line for the model to read in later turns.
    public var line: String { "new project \"\(name)\" with a \(visibility.rawValue) GitHub repository" }
}

public enum ProjectError: Error, Equatable, LocalizedError {
    case badName
    case needsVisibility
    case noProjectsFolder(String)
    case exists(String)
    case notAsked
    case toolMissing(String)
    case stepFailed(step: String, why: String, folderCreated: Bool)
    case noGitIdentity

    public var errorDescription: String? {
        switch self {
        case .badName:
            return "the project needs a plain name: letters, digits, dots, dashes and underscores, starting with a letter or digit"
        case .needsVisibility:
            return "it was not said whether the GitHub repository should be public or private. Ask the user; never choose for them"
        case .noProjectsFolder(let path): return "the projects folder \(path) does not exist"
        case .exists(let name): return "there is already a folder called \"\(name)\" in the projects folder"
        case .notAsked: return "setting up a project was not asked for in the user's message. Ask them to say so plainly"
        case .toolMissing(let tool): return "\(tool) was not found on this Mac"
        case .stepFailed(let step, let why, let folderCreated):
            return "It stopped at \u{201C}\(step)\u{201D}: \(why)"
                + (folderCreated ? " The folder was created and has been left as it is; the later steps were not done." : "")
                + (step.contains("GitHub") ? " The GitHub repository may or may not exist: check on GitHub." : "")
                + (folderCreated ? " To try again, delete the folder first." : "")
        case .noGitIdentity:
            return "Nothing was created. Git does not know your name and email yet, so it could not make the first commit. Set them with \u{201C}git config --global user.name\u{201D} and \u{201C}git config --global user.email\u{201D}, then ask again."
        }
    }
}

public struct CommandResult: Equatable, Sendable {
    public let status: Int32
    public let output: String

    public init(status: Int32, output: String) {
        self.status = status
        self.output = output
    }
}

/// Runs one program with its arguments, never through a shell. Replaced in tests.
public typealias CommandRunner = @Sendable (_ program: URL, _ arguments: [String], _ directory: URL?) async -> CommandResult

public enum Commands {
    /// Runs a program and collects what it printed. The search path is set so
    /// that tools installed by Homebrew can find one another.
    /// No step is waited on for longer than this.
    public static let timeout: TimeInterval = 120

    public static let system: CommandRunner = { program, arguments, directory in
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = program
                process.arguments = arguments
                process.currentDirectoryURL = directory
                var environment = ProcessInfo.processInfo.environment
                environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
                // Nothing here may stop and wait for typing.
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["GH_PROMPT_DISABLED"] = "1"
                process.environment = environment
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice
                do {
                    try process.run()
                } catch {
                    continuation.resume(returning: CommandResult(status: -1, output: error.localizedDescription))
                    return
                }
                // A step that hangs, on the network or on a window asking for a
                // passphrase, is stopped so that it can be reported.
                let timedOut = Flagged()
                let watchdog = DispatchWorkItem {
                    guard process.isRunning else { return }
                    timedOut.set()
                    process.terminate()
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                watchdog.cancel()
                if timedOut.value {
                    continuation.resume(returning: CommandResult(status: -2, output: "it did not finish within \(Int(timeout)) seconds and was stopped"))
                    return
                }
                continuation.resume(returning: CommandResult(status: process.terminationStatus,
                                                             output: String(String(decoding: data, as: UTF8.self).suffix(1200))))
            }
        }
    }

    private final class Flagged: @unchecked Sendable {
        private let lock = NSLock()
        private var on = false
        var value: Bool { lock.withLock { on } }
        func set() { lock.withLock { on = true } }
    }

    /// The first of these programs that exists, if any.
    public static func find(_ name: String, in folders: [String] = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]) -> URL? {
        folders.map { URL(fileURLWithPath: $0).appendingPathComponent(name) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

/// Carries out a project plan. Called only when the user clicks to confirm a preview.
///
/// The steps are fixed and run in order with fixed arguments. Nothing here is
/// decided by a model, and nothing is passed through a shell.
public struct ProjectSetup: Sendable {
    public let git: URL
    public let gh: URL
    public let run: CommandRunner

    public init(git: URL, gh: URL, run: @escaping CommandRunner = Commands.system) {
        self.git = git
        self.gh = gh
        self.run = run
    }

    /// The account `gh` is signed in to, or "" if that cannot be told.
    public func owner() async -> String {
        let result = await run(gh, ["api", "user", "--jq", ".login"], nil)
        let name = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.status == 0 && !name.isEmpty && !name.contains(" ") && name.count <= 60 ? name : ""
    }

    public func perform(_ plan: ProjectPlan, progress: @escaping @Sendable (String) -> Void = { _ in }) async throws {
        let fileManager = FileManager.default
        // Checked before anything is created, so a commit that cannot be made leaves nothing behind.
        progress("Checking git")
        for key in ["user.name", "user.email"] {
            let found = await run(git, ["config", key], nil)
            guard found.status == 0, !found.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ProjectError.noGitIdentity
            }
        }
        progress("Creating the folder")
        do {
            try fileManager.createDirectory(at: plan.folder, withIntermediateDirectories: false)
            let readme = "# \(plan.name)\n" + (plan.summary.map { "\n\($0)\n" } ?? "")
            try readme.write(to: plan.folder.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        } catch {
            throw ProjectError.stepFailed(step: "create the folder", why: error.localizedDescription, folderCreated: false)
        }

        func step(_ title: String, _ program: URL, _ arguments: [String]) async throws {
            progress(title)
            let result = await run(program, arguments, plan.folder)
            guard result.status == 0 else {
                let lines = result.output.split(whereSeparator: \.isNewline).suffix(3).joined(separator: " ")
                throw ProjectError.stepFailed(step: title.prefix(1).lowercased() + title.dropFirst(),
                                              why: lines.isEmpty ? "it failed" : String(lines.prefix(300)), folderCreated: true)
            }
        }
        try await step("Starting git", git, ["init", "-b", "main"])
        try await step("Making the first commit", git, ["add", "README.md"])
        try await step("Making the first commit", git, ["commit", "-m", "Initial commit"])
        var create = ["repo", "create", plan.name, "--\(plan.visibility.rawValue)", "--source", ".", "--remote", "origin", "--push"]
        if let summary = plan.summary { create += ["--description", summary] }
        try await step("Creating the GitHub repository and pushing", gh, create)
    }
}

/// Spots a request to set up a new project, so the tool for it is offered
/// only when the user's own words ask.
public enum ProjectIntent {
    private static let pattern = try! NSRegularExpression(
        pattern: #"\b(set ?up|create|start|make|begin|spin up|new)\b.{0,60}?\b(project|repo|repository)\b"#,
        options: [.caseInsensitive]
    )

    public static func asksToCreate(_ text: String) -> Bool {
        pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}
