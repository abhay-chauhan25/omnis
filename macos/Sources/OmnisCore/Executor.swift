import AppKit
import Foundation

/// Exactly what will happen when an entry is launched. Built only from
/// registry data, never from typed text.
public enum LaunchPlan: Equatable, Sendable {
    case openApplication(URL)
    case openItem(URL, withApplicationBundleID: String)
    /// A program plus a list of arguments. There is no shell involved, so
    /// nothing in a name or path can be interpreted as a command.
    case runExecutable(URL, arguments: [String], workingDirectory: URL)
}

public enum LaunchError: Error, Equatable, LocalizedError {
    case notInRegistry(String)
    case applicationNotInstalled(String)
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .notInRegistry: return "That item is not in the OMNIS registry."
        case .applicationNotInstalled(let id): return "The app \u{201C}\(id)\u{201D} is not installed."
        case .failed(let why): return "Could not open it: \(why)"
        }
    }
}

public protocol LaunchPerforming: Sendable {
    func perform(_ plan: LaunchPlan) async throws
}

/// Turns a registry entry id into an action. The id is the only input, so
/// nothing outside the registry can be launched through this type.
public struct Executor: Sendable {
    public let registry: Registry
    private let performer: LaunchPerforming

    public init(registry: Registry, performer: LaunchPerforming) {
        self.registry = registry
        self.performer = performer
    }

    public func plan(forEntryID id: String) throws -> LaunchPlan {
        guard let entry = registry.entry(id: id) else { throw LaunchError.notInRegistry(id) }
        switch entry.kind {
        case .app:
            return .openApplication(entry.url)
        case .project:
            return .openItem(entry.url, withApplicationBundleID: registry.editor.bundleID)
        case .launcher:
            return .runExecutable(entry.url, arguments: [], workingDirectory: entry.url.deletingLastPathComponent())
        }
    }

    @discardableResult
    public func launch(entryID id: String) async throws -> RegistryEntry {
        let plan = try plan(forEntryID: id)
        try await performer.perform(plan)
        // `plan` succeeded, so the entry exists.
        return registry.entry(id: id)!
    }
}

/// Carries plans out with the real system.
public struct SystemLaunchPerformer: LaunchPerforming {
    /// Called if a launched program later exits with a failure code.
    private let onLateFailure: (@Sendable (URL, Int32) -> Void)?

    public init(onLateFailure: (@Sendable (URL, Int32) -> Void)? = nil) {
        self.onLateFailure = onLateFailure
    }

    public func perform(_ plan: LaunchPlan) async throws {
        switch plan {
        case .openApplication(let url):
            do {
                _ = try await NSWorkspace.shared.openApplication(at: url, configuration: .init())
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }

        case .openItem(let item, let bundleID):
            guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
                throw LaunchError.applicationNotInstalled(bundleID)
            }
            do {
                _ = try await NSWorkspace.shared.open([item], withApplicationAt: appURL, configuration: .init())
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }

        case .runExecutable(let url, let arguments, let workingDirectory):
            let process = Process()
            process.executableURL = url
            process.arguments = arguments
            process.currentDirectoryURL = workingDirectory
            process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            let onLateFailure = self.onLateFailure
            process.terminationHandler = { finished in
                if finished.terminationStatus != 0 {
                    onLateFailure?(url, finished.terminationStatus)
                }
            }
            do {
                try process.run()
            } catch {
                throw LaunchError.failed(error.localizedDescription)
            }
        }
    }
}
