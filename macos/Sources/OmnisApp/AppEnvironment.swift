import Foundation
import OmnisCore

/// Works out how to start the Python backend.
///
/// During development the app bundle records where the repo's `backend`
/// folder and the Python interpreter are (written into Info.plist by
/// `scripts/bundle.sh`). Environment variables override that for debugging.
enum AppEnvironment {
    static func backendConfig() -> BackendConfig? {
        let environment = ProcessInfo.processInfo.environment
        let info = Bundle.main.infoDictionary ?? [:]
        let directory = environment["OMNIS_BACKEND_DIR"] ?? info["OMNISBackendDirectory"] as? String
        let python = environment["OMNIS_PYTHON"] ?? info["OMNISPythonPath"] as? String
        guard let directory, let python, directory.hasPrefix("/"), python.hasPrefix("/") else { return nil }
        let fileManager = FileManager.default
        guard fileManager.isExecutableFile(atPath: python),
              fileManager.fileExists(atPath: directory + "/omnis_backend/__main__.py") else { return nil }
        // Without Ollama the backend still runs, with mock replies.
        let ollamaPath = environment["OMNIS_OLLAMA"] ?? info["OMNISOllamaPath"] as? String
        let ollama = ollamaPath.flatMap { path in
            path.hasPrefix("/") && fileManager.isExecutableFile(atPath: path) ? URL(fileURLWithPath: path) : nil
        }
        return .python(
            URL(fileURLWithPath: python),
            backendDirectory: URL(fileURLWithPath: directory, isDirectory: true),
            ollama: ollama
        )
    }

    /// Development aid: `--show-on-launch` opens the popup immediately, and
    /// `--query <text>` pre-fills it. Used for screenshots and manual checks.
    static var showOnLaunch: Bool { CommandLine.arguments.contains("--show-on-launch") }

    static var initialQuery: String? {
        let arguments = CommandLine.arguments
        guard let index = arguments.firstIndex(of: "--query"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }
}
