import Foundation

/// The three kinds of thing the launcher knows how to open.
public enum EntryKind: String, Codable, Sendable, CaseIterable {
    case app
    case project
    case launcher
}

/// One launchable thing. Entries are only ever created by `Registry.load`,
/// and the executor will run nothing that is not an entry.
public struct RegistryEntry: Equatable, Identifiable, Sendable {
    public let kind: EntryKind
    public let name: String
    public let url: URL

    public var id: String { RegistryEntry.makeID(kind: kind, name: name) }

    public static func makeID(kind: EntryKind, name: String) -> String {
        "\(kind.rawValue):\(name)"
    }
}

public struct LauncherSpec: Codable, Equatable, Sendable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct EditorSpec: Codable, Equatable, Sendable {
    public var name: String
    public var bundleID: String

    public init(name: String, bundleID: String) {
        self.name = name
        self.bundleID = bundleID
    }
}

/// The user-editable settings file (`registry.json`).
public struct RegistryConfig: Codable, Equatable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    /// Folders scanned for `.app` bundles (two levels deep, so `Utilities` is included).
    public var appRoots: [String]
    /// Folders whose direct subfolders are treated as projects.
    public var projectRoots: [String]
    /// The editor projects open in.
    public var editor: EditorSpec
    /// Custom launchers: a name and the fixed path of a script or program.
    public var launchers: [LauncherSpec]
    /// Typed phrase -> entry id (for example "voyager" -> "project:VoyagerAI").
    public var aliases: [String: String]

    public init(
        version: Int = RegistryConfig.currentVersion,
        appRoots: [String],
        projectRoots: [String],
        editor: EditorSpec,
        launchers: [LauncherSpec] = [],
        aliases: [String: String] = [:]
    ) {
        self.version = version
        self.appRoots = appRoots
        self.projectRoots = projectRoots
        self.editor = editor
        self.launchers = launchers
        self.aliases = aliases
    }

    public static let standard = RegistryConfig(
        appRoots: ["/Applications", "/System/Applications"],
        projectRoots: ["~/projects"],
        editor: EditorSpec(name: "VS Code", bundleID: "com.microsoft.VSCode")
    )
}

public enum RegistryError: Error, Equatable, LocalizedError {
    case unsupportedVersion(Int)
    case unreadableConfig(String)
    case relativePath(String)
    case missing(String)
    case notAFile(String)
    case notExecutable(String)
    case emptyName
    case unknownAliasTarget(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let v): return "Settings file version \(v) is not supported."
        case .unreadableConfig(let why): return "Settings file could not be read: \(why)"
        case .relativePath(let p): return "\u{201C}\(p)\u{201D} is not a full path."
        case .missing(let p): return "\u{201C}\(p)\u{201D} does not exist."
        case .notAFile(let p): return "\u{201C}\(p)\u{201D} is not a file."
        case .notExecutable(let p): return "\u{201C}\(p)\u{201D} is not runnable."
        case .emptyName: return "A launcher has no name."
        case .unknownAliasTarget(let t): return "Alias points at \u{201C}\(t)\u{201D}, which is not in the registry."
        }
    }
}

/// The set of things OMNIS may launch, built from the settings file and the disk.
public struct Registry: Sendable {
    public let entries: [RegistryEntry]
    /// Normalised phrase -> entry id.
    public let aliases: [String: String]
    public let editor: EditorSpec
    /// Human-readable notes about settings that were skipped.
    public let warnings: [String]

    private let byID: [String: RegistryEntry]

    public init(entries: [RegistryEntry], aliases: [String: String] = [:], editor: EditorSpec, warnings: [String] = []) {
        var seen: [String: RegistryEntry] = [:]
        var ordered: [RegistryEntry] = []
        for entry in entries where seen[entry.id] == nil {
            seen[entry.id] = entry
            ordered.append(entry)
        }
        self.entries = ordered
        self.byID = seen
        self.aliases = aliases
        self.editor = editor
        self.warnings = warnings
    }

    public func entry(id: String) -> RegistryEntry? { byID[id] }

    /// Expands a leading `~` and insists on a full path.
    public static func resolve(path: String, home: URL) throws -> URL {
        var expanded = path
        if expanded == "~" {
            expanded = home.path
        } else if expanded.hasPrefix("~/") {
            expanded = home.path + String(expanded.dropFirst(1))
        }
        guard expanded.hasPrefix("/") else { throw RegistryError.relativePath(path) }
        return URL(fileURLWithPath: expanded).standardizedFileURL
    }

    /// Checks one custom launcher. Throws if it must not be registered.
    public static func validate(
        launcher: LauncherSpec,
        home: URL,
        fileManager: FileManager = .default
    ) throws -> RegistryEntry {
        let name = launcher.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw RegistryError.emptyName }
        let url = try resolve(path: launcher.path, home: home)
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            throw RegistryError.missing(launcher.path)
        }
        guard !isDirectory.boolValue else { throw RegistryError.notAFile(launcher.path) }
        guard fileManager.isExecutableFile(atPath: url.path) else {
            throw RegistryError.notExecutable(launcher.path)
        }
        return RegistryEntry(kind: .launcher, name: name, url: url)
    }

    /// Builds the registry. A bad individual entry is skipped with a warning;
    /// an unsupported settings version is refused outright.
    public static func load(
        config: RegistryConfig,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) throws -> Registry {
        guard config.version == RegistryConfig.currentVersion else {
            throw RegistryError.unsupportedVersion(config.version)
        }
        var warnings: [String] = []
        var entries: [RegistryEntry] = []

        func note(_ subject: String, _ error: Error) {
            warnings.append("\(subject) skipped: \(error.localizedDescription)")
        }

        for spec in config.launchers {
            do {
                entries.append(try validate(launcher: spec, home: home, fileManager: fileManager))
            } catch {
                note("Launcher \u{201C}\(spec.name)\u{201D}", error)
            }
        }

        for root in config.projectRoots {
            do {
                let url = try resolve(path: root, home: home)
                entries.append(contentsOf: projects(in: url, fileManager: fileManager))
            } catch {
                note("Project folder \u{201C}\(root)\u{201D}", error)
            }
        }

        for root in config.appRoots {
            do {
                let url = try resolve(path: root, home: home)
                entries.append(contentsOf: apps(in: url, depth: 2, fileManager: fileManager))
            } catch {
                note("App folder \u{201C}\(root)\u{201D}", error)
            }
        }

        let provisional = Registry(entries: entries, editor: config.editor)
        var aliases: [String: String] = [:]
        for (phrase, target) in config.aliases.sorted(by: { $0.key < $1.key }) {
            let key = TextNormalizer.normalize(phrase)
            guard !key.isEmpty else { continue }
            guard provisional.entry(id: target) != nil else {
                note("Alias \u{201C}\(phrase)\u{201D}", RegistryError.unknownAliasTarget(target))
                continue
            }
            aliases[key] = target
        }

        return Registry(entries: provisional.entries, aliases: aliases, editor: config.editor, warnings: warnings)
    }

    static func projects(in root: URL, fileManager: FileManager) -> [RegistryEntry] {
        let items = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return items
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .map { RegistryEntry(kind: .project, name: $0.lastPathComponent, url: $0.standardizedFileURL) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func apps(in root: URL, depth: Int, fileManager: FileManager) -> [RegistryEntry] {
        guard depth > 0 else { return [] }
        let items = (try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        var found: [RegistryEntry] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if item.pathExtension == "app" {
                let name = item.deletingPathExtension().lastPathComponent
                found.append(RegistryEntry(kind: .app, name: name, url: item.standardizedFileURL))
            } else if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                found.append(contentsOf: apps(in: item, depth: depth - 1, fileManager: fileManager))
            }
        }
        return found
    }
}

/// Reads the settings file, creating it with defaults on first run.
public enum ConfigStore {
    public static func loadOrCreate(at url: URL, defaults: RegistryConfig = .standard) throws -> RegistryConfig {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                            attributes: [.posixPermissions: 0o700])
            try encode(defaults).write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return defaults
        }
        do {
            return try JSONDecoder().decode(RegistryConfig.self, from: Data(contentsOf: url))
        } catch {
            throw RegistryError.unreadableConfig(error.localizedDescription)
        }
    }

    public static func encode(_ config: RegistryConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(config)
    }
}

/// Where OMNIS keeps its runtime files.
public enum OmnisPaths {
    public static var supportDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/OMNIS", isDirectory: true)
    }

    public static var registryFile: URL { supportDirectory.appendingPathComponent("registry.json") }
    public static var auditLog: URL { supportDirectory.appendingPathComponent("audit.log") }
}
