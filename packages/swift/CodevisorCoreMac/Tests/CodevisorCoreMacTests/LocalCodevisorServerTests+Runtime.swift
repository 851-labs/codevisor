import Foundation
import Testing
import ACPKit
@testable import CodevisorCore
@testable import CodevisorCoreMac

extension LocalCodevisorServerTests {
    @Test("Launch command names the server process")
    func launchCommandNamesServerProcess() {
        let request = LocalCodevisorServerLaunchRequest(
            nodeExecutable: URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            entrypoint: URL(fileURLWithPath: "/tmp/codevisor-server/main.js"),
            databasePath: "/tmp/codevisor.sqlite",
            logURL: URL(fileURLWithPath: "/tmp/codevisor-server.log"),
            host: "0.0.0.0",
            port: 49362,
            name: "Test Mac",
            environment: [:]
        )

        let configuration = LocalCodevisorServer.processConfiguration(for: request)

        #expect(configuration.executableURL.path == "/bin/bash")
        #expect(
            Array(configuration.arguments.prefix(3)) == [
                "-c",
                "exec -a codevisor-server \"$0\" \"$@\"",
                "/opt/homebrew/bin/node",
            ])
        #expect(
            Array(configuration.arguments.dropFirst(3).prefix(2)) == [
                "/tmp/codevisor-server/main.js",
                "serve",
            ])
        #expect(configuration.arguments.contains("--boot-id"))
        #expect(configuration.arguments.contains("test-boot"))
        #expect(configuration.arguments.contains("--app-owned"))
        #expect(configuration.arguments.contains("--owner-pid"))
    }

    @Test("Launch command preserves PATH lookup when Node falls back to env")
    func launchCommandUsesPathLookupForEnvFallback() {
        let request = LocalCodevisorServerLaunchRequest(
            nodeExecutable: URL(fileURLWithPath: "/usr/bin/env"),
            entrypoint: URL(fileURLWithPath: "/tmp/codevisor-server/main.js"),
            databasePath: "/tmp/codevisor.sqlite",
            logURL: URL(fileURLWithPath: "/tmp/codevisor-server.log"),
            host: "0.0.0.0",
            port: 49362,
            name: "Test Mac",
            environment: ["PATH": "/opt/homebrew/bin:/usr/bin"]
        )

        let configuration = LocalCodevisorServer.processConfiguration(for: request)

        #expect(configuration.executableURL.path == "/bin/bash")
        #expect(configuration.arguments.dropFirst(2).first == "node")
    }

    @Test("Resolves the bundled runtime directory by path, not Bundle resource lookup")
    func bundledRuntimeDirectoryByPath() throws {
        let resources = try makeTemporaryDirectory()
        #if arch(x86_64)
            let target = "darwin-x64"
        #else
            let target = "darwin-arm64"
        #endif
        let runtime = resources.appendingPathComponent("server/\(target)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent("bin"),
            withIntermediateDirectories: true
        )
        FileManager.default.createFile(atPath: runtime.appendingPathComponent("main.js").path, contents: Data())
        FileManager.default.createFile(
            atPath: runtime.appendingPathComponent("bin/node").path,
            contents: Data(),
            attributes: [.posixPermissions: 0o755]
        )

        let resolved = LocalCodevisorServer.bundledServerRuntimeDirectory(resourcesURL: resources)

        #expect(resolved?.standardizedFileURL.path == runtime.standardizedFileURL.path)
    }

    @Test("Migrates legacy Application Support server data into ~/.codevisor")
    func migratesLegacyServerData() throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Application Support/Codevisor", isDirectory: true)
        let data = root.appendingPathComponent(".codevisor/data", isDirectory: true)
        let logs = root.appendingPathComponent(".codevisor/logs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(
            at: legacy.appendingPathComponent("harness-secrets/claude-code", isDirectory: true),
            withIntermediateDirectories: true
        )
        try fm.createDirectory(
            at: legacy.appendingPathComponent("attachments/objects/sha256/ab", isDirectory: true),
            withIntermediateDirectories: true
        )
        try "database".write(
            to: legacy.appendingPathComponent("codevisor-server.sqlite"),
            atomically: true, encoding: .utf8
        )
        try "wal".write(
            to: legacy.appendingPathComponent("codevisor-server.sqlite-wal"),
            atomically: true, encoding: .utf8
        )
        try "log".write(
            to: legacy.appendingPathComponent("server.log"), atomically: true, encoding: .utf8
        )
        try "sk".write(
            to: legacy.appendingPathComponent("harness-secrets/claude-code/api-key"),
            atomically: true, encoding: .utf8
        )
        try "attachment".write(
            to: legacy.appendingPathComponent("attachments/objects/sha256/ab/abcdef"),
            atomically: true, encoding: .utf8
        )
        try "keep".write(
            to: legacy.appendingPathComponent("themes.json"), atomically: true, encoding: .utf8
        )

        LocalCodevisorServer.migrateLegacyServerData(from: legacy, toData: data, logs: logs)

        #expect(
            try String(contentsOf: data.appendingPathComponent("codevisor-server.sqlite"), encoding: .utf8)
                == "database"
        )
        #expect(
            try String(contentsOf: data.appendingPathComponent("codevisor-server.sqlite-wal"), encoding: .utf8)
                == "wal"
        )
        #expect(
            try String(contentsOf: data.appendingPathComponent("harness-secrets/claude-code/api-key"), encoding: .utf8)
                == "sk"
        )
        #expect(
            try String(
                contentsOf: data.appendingPathComponent("attachments/objects/sha256/ab/abcdef"),
                encoding: .utf8
            ) == "attachment"
        )
        #expect(
            try String(contentsOf: logs.appendingPathComponent("server.log"), encoding: .utf8) == "log"
        )
        // Client-side files stay behind; only server state moves.
        #expect(fm.fileExists(atPath: legacy.appendingPathComponent("themes.json").path))
        #expect(!fm.fileExists(atPath: legacy.appendingPathComponent("codevisor-server.sqlite").path))
    }

    @Test("Skips migration when the canonical database already exists")
    func skipsMigrationWhenDestinationExists() throws {
        let root = try makeTemporaryDirectory()
        let legacy = root.appendingPathComponent("Application Support/Codevisor", isDirectory: true)
        let data = root.appendingPathComponent(".codevisor/data", isDirectory: true)
        let logs = root.appendingPathComponent(".codevisor/logs", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: legacy, withIntermediateDirectories: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true)
        try "stale".write(
            to: legacy.appendingPathComponent("codevisor-server.sqlite"),
            atomically: true, encoding: .utf8
        )
        try "current".write(
            to: data.appendingPathComponent("codevisor-server.sqlite"),
            atomically: true, encoding: .utf8
        )

        LocalCodevisorServer.migrateLegacyServerData(from: legacy, toData: data, logs: logs)

        #expect(
            try String(contentsOf: data.appendingPathComponent("codevisor-server.sqlite"), encoding: .utf8)
                == "current"
        )
        #expect(
            try String(contentsOf: legacy.appendingPathComponent("codevisor-server.sqlite"), encoding: .utf8)
                == "stale"
        )
    }
}
