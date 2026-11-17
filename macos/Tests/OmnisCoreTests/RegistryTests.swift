import Foundation
import Testing
@testable import OmnisCore

@Suite struct RegistryTests {
    @Test func launcherMustBeAFullPathToARunnableFile() throws {
        let scratch = try Scratch()
        let good = try scratch.file("tools/run-me", contents: "#!/bin/sh\n", executable: true)
        try scratch.file("tools/not-runnable", contents: "data")
        try scratch.folder("tools/a-folder")
        let home = scratch.url

        let entry = try Registry.validate(launcher: LauncherSpec(name: " Runner ", path: good.path), home: home)
        #expect(entry == RegistryEntry(kind: .launcher, name: "Runner", url: good))

        func refusal(_ path: String, name: String = "X") -> RegistryError? {
            do {
                _ = try Registry.validate(launcher: LauncherSpec(name: name, path: path), home: home)
                return nil
            } catch {
                return error as? RegistryError
            }
        }
        #expect(refusal("tools/run-me") == .relativePath("tools/run-me"))
        #expect(refusal("./run-me") == .relativePath("./run-me"))
        #expect(refusal("") == .relativePath(""))
        #expect(refusal(home.path + "/tools/gone") == .missing(home.path + "/tools/gone"))
        #expect(refusal(home.path + "/tools/a-folder") == .notAFile(home.path + "/tools/a-folder"))
        #expect(refusal(home.path + "/tools/not-runnable") == .notExecutable(home.path + "/tools/not-runnable"))
        #expect(refusal(good.path, name: "  ") == .emptyName)
    }

    @Test func tildeExpandsToHome() throws {
        let scratch = try Scratch()
        let script = try scratch.file("bin/tool", contents: "#!/bin/sh\n", executable: true)
        let entry = try Registry.validate(launcher: LauncherSpec(name: "Tool", path: "~/bin/tool"), home: scratch.url)
        #expect(entry.url == script)
        // "~user" forms are not expanded and so are refused as relative.
        #expect(throws: RegistryError.relativePath("~root/bin/tool")) {
            try Registry.validate(launcher: LauncherSpec(name: "Tool", path: "~root/bin/tool"), home: scratch.url)
        }
    }

    @Test func dotDotSegmentsAreResolvedBeforeUse() throws {
        let scratch = try Scratch()
        let script = try scratch.file("bin/tool", contents: "#!/bin/sh\n", executable: true)
        try scratch.folder("other")
        let entry = try Registry.validate(
            launcher: LauncherSpec(name: "Tool", path: scratch.url.path + "/other/../bin/tool"),
            home: scratch.url
        )
        #expect(entry.url.path == script.path)
    }

    @Test func loadDiscoversAppsProjectsAndLaunchers() throws {
        let scratch = try Scratch()
        try scratch.folder("Applications/Alpha.app")
        try scratch.folder("Applications/Utilities/Beta.app")
        try scratch.folder("Applications/Utilities/Deep/Gamma.app")
        try scratch.file("Applications/readme.txt")
        try scratch.folder("projects/VoyagerAI")
        try scratch.folder("projects/Voyagers")
        try scratch.folder("projects/.hidden")
        try scratch.file("projects/notes.txt")
        try scratch.file("ghidra/ghidraRun", contents: "#!/bin/sh\n", executable: true)

        let config = RegistryConfig(
            appRoots: [scratch.url.path + "/Applications"],
            projectRoots: ["~/projects"],
            editor: vsCode,
            launchers: [
                LauncherSpec(name: "Ghidra", path: "~/ghidra/ghidraRun"),
                LauncherSpec(name: "Broken", path: "~/ghidra/missing"),
                LauncherSpec(name: "Relative", path: "ghidra/ghidraRun"),
            ],
            aliases: ["Voyager": "project:VoyagerAI", "ghost": "project:DoesNotExist", "odd": "shell:rm"]
        )
        let registry = try Registry.load(config: config, home: scratch.url)
        let ids = Set(registry.entries.map(\.id))

        #expect(ids == ["launcher:Ghidra", "project:VoyagerAI", "project:Voyagers", "app:Alpha", "app:Beta"])
        #expect(registry.aliases == ["voyager": "project:VoyagerAI"])
        #expect(registry.warnings.count == 4)
        #expect(registry.warnings.contains { $0.contains("Broken") })
        #expect(registry.warnings.contains { $0.contains("Relative") })
        #expect(registry.warnings.contains { $0.contains("ghost") })
        #expect(registry.warnings.contains { $0.contains("odd") })
        #expect(registry.entry(id: "project:VoyagerAI")?.url.path == scratch.url.path + "/projects/VoyagerAI")
    }

    @Test func missingRootsAreNotAnError() throws {
        let scratch = try Scratch()
        let config = RegistryConfig(appRoots: ["/definitely/not/here"], projectRoots: ["~/nope", "relative/root"], editor: vsCode)
        let registry = try Registry.load(config: config, home: scratch.url)
        #expect(registry.entries.isEmpty)
        #expect(registry.warnings.count == 1)
    }

    @Test func unsupportedVersionIsRefused() throws {
        var config = RegistryConfig.standard
        config.version = 2
        #expect(throws: RegistryError.unsupportedVersion(2)) {
            try Registry.load(config: config)
        }
    }

    @Test func duplicateNamesKeepTheFirst() {
        let a = RegistryEntry(kind: .app, name: "Same", url: URL(fileURLWithPath: "/Applications/Same.app"))
        let b = RegistryEntry(kind: .app, name: "Same", url: URL(fileURLWithPath: "/System/Applications/Same.app"))
        let registry = Registry(entries: [a, b], editor: vsCode)
        #expect(registry.entries == [a])
        #expect(registry.entry(id: "app:Same")?.url == a.url)
    }

    @Test func settingsFileIsCreatedThenReadBack() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("nested/registry.json")
        let created = try ConfigStore.loadOrCreate(at: file)
        #expect(created == RegistryConfig.standard)
        #expect(FileManager.default.fileExists(atPath: file.path))

        var edited = created
        edited.launchers = [LauncherSpec(name: "Ghidra", path: "~/x/ghidraRun")]
        edited.aliases = ["voyager": "project:VoyagerAI"]
        try ConfigStore.encode(edited).write(to: file)
        #expect(try ConfigStore.loadOrCreate(at: file) == edited)
    }

    @Test func settingsFolderAndFileArePrivate() throws {
        let scratch = try Scratch()
        let file = scratch.url.appendingPathComponent("OMNIS/registry.json")
        _ = try ConfigStore.loadOrCreate(at: file)
        let attributes = FileManager.default
        #expect(try attributes.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int == 0o600)
        #expect(try attributes.attributesOfItem(atPath: file.deletingLastPathComponent().path)[.posixPermissions] as? Int == 0o700)
    }

    @Test func loadingTheRealFoldersIsFastEnoughToDoOnEveryOpen() throws {
        let clock = ContinuousClock()
        var registry: Registry?
        let elapsed = try clock.measure { registry = try Registry.load(config: .standard) }
        let milliseconds = Double(elapsed.components.attoseconds) / 1e15 + Double(elapsed.components.seconds) * 1000
        print("REGISTRY_LOAD_MS \(milliseconds) entries \(registry?.entries.count ?? 0)")
        #expect(elapsed < .milliseconds(250))
    }

    @Test func unreadableSettingsFileIsReportedNotOverwritten() throws {
        let scratch = try Scratch()
        let file = try scratch.file("registry.json", contents: "{ not json")
        #expect(throws: RegistryError.self) { try ConfigStore.loadOrCreate(at: file) }
        #expect(try String(contentsOf: file, encoding: .utf8) == "{ not json")
    }

    @Test func settingsWithAnUnknownShapeAreRefused() throws {
        let scratch = try Scratch()
        let file = try scratch.file("registry.json", contents: #"{"version":1,"launchers":[{"kind":"shell","command":"rm -rf /"}]}"#)
        #expect(throws: RegistryError.self) { try ConfigStore.loadOrCreate(at: file) }
    }
}
