import Foundation
@testable import OmnisCore

/// A scratch folder that is removed when the test ends.
final class Scratch {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("omnis-tests-\(UUID().uuidString)", isDirectory: true)
            .resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    @discardableResult
    func folder(_ path: String) throws -> URL {
        let target = url.appendingPathComponent(path, isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return target
    }

    @discardableResult
    func file(_ path: String, contents: String = "", executable: Bool = false) throws -> URL {
        let target = url.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: target, atomically: true, encoding: .utf8)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: target.path)
        }
        return target
    }
}

let vsCode = EditorSpec(name: "VS Code", bundleID: "com.microsoft.VSCode")

/// A registry shaped like the real machine: two Voyager folders, ChatGPT Classic, Ghidra.
func sampleRegistry(aliases: [String: String] = ["voyager": "project:VoyagerAI"]) -> Registry {
    func app(_ name: String) -> RegistryEntry {
        RegistryEntry(kind: .app, name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }
    func project(_ name: String) -> RegistryEntry {
        RegistryEntry(kind: .project, name: name, url: URL(fileURLWithPath: "/Users/someone/projects/\(name)"))
    }
    let entries = [
        RegistryEntry(kind: .launcher, name: "Ghidra", url: URL(fileURLWithPath: "/opt/ghidra/ghidraRun")),
        project("CloudSocAI"), project("VoyagerAI"), project("Voyagers"), project("omnis"),
        app("ChatGPT Classic"), app("Calculator"), app("Visual Studio Code"), app("Safari"),
        app("System Settings"), app("Xcode"), app("Voice Memos"),
    ]
    return Registry(entries: entries, aliases: aliases, editor: vsCode)
}

func waitUntil(timeout: TimeInterval = 5, _ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}
