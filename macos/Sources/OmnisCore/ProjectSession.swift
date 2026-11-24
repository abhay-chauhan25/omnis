import Foundation

/// How a Claude Code terminal is started for a project.
///
/// The session is the user's own Claude Code, exactly as if they had run
/// `claude` in the project's folder. OMNIS adds no rules of its own: what the
/// session may do without asking is whatever the user's Claude Code settings say.
public enum ProjectSession {
    /// The options for one session. `brief` is typed in as its first message.
    public static func arguments(name: String, resume: Bool = false, brief: String? = nil) -> [String] {
        var arguments = ["--name", name]
        if resume { arguments.append("--continue") }
        // After "--", so a brief can never be read as an option.
        if let brief = brief?.trimmingCharacters(in: .whitespacesAndNewlines), !brief.isEmpty {
            arguments += ["--", brief]
        }
        return arguments
    }

    /// Starts Claude Code through the user's login shell, so it sees the same
    /// tools on its search path as in their own terminal. The options are
    /// handed over as separate arguments and never become part of a command line.
    public static func launch(claude: URL, arguments: [String], shell: String = "/bin/zsh") -> (executable: String, arguments: [String]) {
        // A login, interactive shell reads the same start-up files as the
        // user's own terminal, so tools such as npm are found the same way.
        (shell, ["-l", "-i", "-c", "exec \"$0\" \"$@\"", claude.path] + arguments)
    }

    /// Text made safe to place in a terminal's input. See `ProjectFiles.pasteable`.
    public static func pasteable(_ text: String) -> String { ProjectFiles.pasteable(text) }

    /// Where Claude Code keeps the sessions of a project folder.
    public static func transcriptFolder(for project: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        let path = project.resolvingSymlinksInPath().path
        let encoded = String(path.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "-" })
        return home.appendingPathComponent(".claude/projects", isDirectory: true).appendingPathComponent(encoded, isDirectory: true)
    }
}

/// What a Claude Code session has been doing, read from the record it keeps of itself.
public struct SessionActivity: Equatable, Sendable {
    public struct TaskItem: Equatable, Sendable, Identifiable {
        public let text: String
        /// "pending", "in_progress" or "completed".
        public let state: String
        public var id: String { text }
    }

    public var title: String?
    /// The last thing the user asked it.
    public var lastPrompt: String?
    /// Its most recent steps in plain words, oldest first.
    public var steps: [String] = []
    /// The last thing it said.
    public var lastText: String?
    public var tasks: [TaskItem] = []
    public var updated: Date?

    public var isEmpty: Bool { steps.isEmpty && lastText == nil && lastPrompt == nil && tasks.isEmpty }
}

/// Reads Claude Code's own session records for a project. Read only.
///
/// The layout of these files belongs to Claude Code and can change. Anything
/// not understood is skipped, and the worst outcome is that less is shown.
public enum SessionTranscripts {
    /// The session most recently written to.
    public static func latest(in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        return files.filter { $0.pathExtension == "jsonl" }.max { a, b in
            let first = (try? a.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let second = (try? b.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return first < second
        }
    }

    public static func load(project: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                            maxBytes: Int = 600_000) -> SessionActivity? {
        guard let file = latest(in: ProjectSession.transcriptFolder(for: project, home: home)),
              let handle = try? FileHandle(forReadingFrom: file) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        guard var data = try? handle.readToEnd() else { return nil }
        // The first line may be cut in half when only the end was read.
        if start > 0, let newline = data.firstIndex(of: 0x0A) { data = data.subdata(in: data.index(after: newline)..<data.endIndex) }
        var activity = activity(from: data)
        activity.updated = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return activity.isEmpty ? nil : activity
    }

    static func short(_ text: String, _ limit: Int = 140) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return flat.count > limit ? String(flat.prefix(limit - 1)) + "\u{2026}" : flat
    }

    /// One step in plain words.
    static func describe(tool: String, input: [String: Any]) -> String? {
        func name(_ key: String) -> String? {
            (input[key] as? String).map { URL(fileURLWithPath: $0).lastPathComponent }
        }
        switch tool {
        case "Bash": return "Ran: " + short((input["description"] as? String) ?? (input["command"] as? String) ?? "a command", 110)
        case "Edit", "MultiEdit", "NotebookEdit": return name("file_path").map { "Edited \($0)" } ?? "Edited a file"
        case "Write": return name("file_path").map { "Wrote \($0)" } ?? "Wrote a file"
        case "Read": return name("file_path").map { "Read \($0)" } ?? "Read a file"
        case "Glob", "Grep": return "Searched the code" + ((input["pattern"] as? String).map { " for \(short($0, 60))" } ?? "")
        case "Agent", "Task": return "Started an agent: " + short((input["description"] as? String) ?? "a sub-task", 100)
        case "WebSearch": return "Searched the web"
        case "WebFetch": return "Read a web page"
        case "TodoWrite", "TaskCreate", "TaskUpdate", "TaskList", "TaskGet": return nil
        default: return "Used \(short(tool, 40))"
        }
    }

    public static func activity(from data: Data, maxSteps: Int = 8) -> SessionActivity {
        var activity = SessionActivity()
        for line in data.split(separator: 0x0A) {
            guard let entry = try? JSONSerialization.jsonObject(with: Data(line)) as? [String: Any] else { continue }
            switch entry["type"] as? String {
            case "ai-title":
                if let title = entry["aiTitle"] as? String { activity.title = short(title, 80) }
            case "last-prompt":
                if let prompt = entry["lastPrompt"] as? String { activity.lastPrompt = short(prompt, 200) }
            case "assistant":
                // Work done by an agent it started is part of its own record, not listed step by step.
                guard entry["isSidechain"] as? Bool != true, let message = entry["message"] as? [String: Any],
                      let blocks = message["content"] as? [[String: Any]] else { continue }
                for block in blocks {
                    switch block["type"] as? String {
                    case "text":
                        if let text = block["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                            activity.lastText = short(text, 400)
                        }
                    case "tool_use":
                        let tool = block["name"] as? String ?? ""
                        let input = block["input"] as? [String: Any] ?? [:]
                        if tool == "TodoWrite", let todos = input["todos"] as? [[String: Any]] {
                            activity.tasks = todos.prefix(20).compactMap { todo in
                                (todo["content"] as? String).map {
                                    SessionActivity.TaskItem(text: short($0, 120), state: todo["status"] as? String ?? "pending")
                                }
                            }
                        } else if tool == "TaskCreate", let subject = (input["subject"] as? String) ?? (input["description"] as? String) {
                            let item = SessionActivity.TaskItem(text: short(subject, 120), state: "pending")
                            if !activity.tasks.contains(item), activity.tasks.count < 20 { activity.tasks.append(item) }
                        } else if let step = describe(tool: tool, input: input) {
                            activity.steps.append(step)
                        }
                    default:
                        break
                    }
                }
            default:
                break
            }
        }
        activity.steps = Array(activity.steps.suffix(maxSteps))
        return activity
    }

    /// A short account of the session for the advisor to read with a question.
    public static func brief(_ activity: SessionActivity?, changedFiles: [String]) -> String {
        var lines: [String] = []
        if let activity {
            if let title = activity.title { lines.append("Session: \(title)") }
            if let prompt = activity.lastPrompt { lines.append("The user last asked it: \(prompt)") }
            if !activity.steps.isEmpty { lines.append("Its latest steps:\n" + activity.steps.map { "- \($0)" }.joined(separator: "\n")) }
            if !activity.tasks.isEmpty {
                lines.append("Its task list:\n" + activity.tasks.map { "- [\($0.state)] \($0.text)" }.joined(separator: "\n"))
            }
            if let text = activity.lastText { lines.append("The last thing it said: \(text)") }
        } else {
            lines.append("No Claude Code session has been recorded for this project yet.")
        }
        if !changedFiles.isEmpty {
            lines.append("Files changed and not yet committed:\n" + changedFiles.prefix(30).map { "- \($0)" }.joined(separator: "\n"))
        }
        return lines.joined(separator: "\n\n")
    }
}

public enum ProjectFiles {
    /// The files git reports as changed, as "M path" lines.
    public static func changed(in folder: URL, git: URL, run: CommandRunner = Commands.system) async -> [String] {
        // Without taking git's lock, so this never gets in the way of a commit the session is making.
        let result = await run(git, ["--no-optional-locks", "status", "--porcelain"], folder)
        guard result.status == 0 else { return [] }
        return result.output.split(whereSeparator: \.isNewline).prefix(60).map { line in
            let code = line.prefix(2).trimmingCharacters(in: .whitespaces)
            return "\(code.isEmpty ? "?" : code) \(line.dropFirst(3))"
        }
    }

    /// Whether a file the advisor asked to read is inside the project and is
    /// not one that usually holds secrets.
    public static func mayRead(_ path: String?, in folder: URL) -> Bool {
        guard let path, !path.isEmpty else { return true }      // no path means the project folder itself
        let root = folder.resolvingSymlinksInPath().path
        let target = (path.hasPrefix("/") ? URL(fileURLWithPath: path) : folder.appendingPathComponent(path))
            .standardizedFileURL.resolvingSymlinksInPath()
        guard target.path == root || target.path.hasPrefix(root + "/") else { return false }
        let name = target.lastPathComponent.lowercased()
        let lowered = target.pathComponents.map { $0.lowercased() }
        return !looksSecret(name) && !lowered.contains(".git") && !lowered.contains(".aws") && !lowered.contains(".ssh")
            && !lowered.contains(".docker") && !lowered.contains(".gnupg")
    }

    /// Whether a search pattern stays inside the project: not an absolute path and no climbing out.
    public static func patternStaysInside(_ pattern: String?) -> Bool {
        guard let pattern, !pattern.isEmpty else { return true }
        return !pattern.hasPrefix("/") && !pattern.hasPrefix("~") && !pattern.contains("..")
    }

    static func looksSecret(_ name: String) -> Bool {
        let exact: Set<String> = [".env", ".envrc", ".netrc", ".npmrc", ".pypirc", ".git-credentials", ".htpasswd",
                                  "credentials", "credentials.json", "kubeconfig"]
        let endings = [".pem", ".key", ".p12", ".pfx", ".p8", ".jks", ".ppk", ".gpg", ".kdbx", ".keystore", ".tfvars"]
        return exact.contains(name) || name.hasPrefix(".env.") || name.hasPrefix("id_rsa") || name.hasPrefix("id_ed25519")
            || name.hasPrefix("secrets.") || name.hasPrefix("service-account") || name.hasPrefix("terraform.tfstate")
            || endings.contains(where: name.hasSuffix)
    }

    /// Text made safe to place in a terminal's input: control characters are
    /// removed, so nothing in it can end the paste early or press a key.
    /// Line breaks and tabs are kept.
    public static func pasteable(_ text: String) -> String {
        String(String.UnicodeScalarView(text.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || !(scalar.value < 0x20 || (0x7F...0x9F).contains(scalar.value))
        })).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
