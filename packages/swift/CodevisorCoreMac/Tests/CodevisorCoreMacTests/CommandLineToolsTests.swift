import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("CommandLineTools")
struct CommandLineToolsTests {
    private let fileManager = FileManager.default

    /// A throwaway root with a fake app-bundle runtime and an empty bin dir.
    private func makeFixture() throws -> (root: URL, runtime: URL, bin: URL) {
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("cli-tools-\(UUID().uuidString)", isDirectory: true)
        let runtime = try makeRuntime(in: root, bundleName: "Codevisor.app")
        let bin = root.appendingPathComponent("bin", isDirectory: true)
        return (root, runtime, bin)
    }

    private func makeRuntime(in root: URL, bundleName: String) throws -> URL {
        let runtime = root.appendingPathComponent(
            "\(bundleName)/Contents/Resources/server/darwin-arm64",
            isDirectory: true
        )
        let binDirectory = runtime.appendingPathComponent("bin", isDirectory: true)
        try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        for name in CommandLineTools.launcherNames {
            let launcher = binDirectory.appendingPathComponent(name)
            try "#!/bin/sh\n".write(to: launcher, atomically: true, encoding: .utf8)
            try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: launcher.path)
        }
        return runtime
    }

    private func destination(of link: URL) -> String? {
        try? fileManager.destinationOfSymbolicLink(atPath: link.path)
    }

    @Test("Creates all launcher links when none exist")
    func createsLinks() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        for name in CommandLineTools.launcherNames {
            let expected = runtime.appendingPathComponent("bin/\(name)").path
            #expect(destination(of: bin.appendingPathComponent(name)) == expected)
        }
    }

    @Test("Is idempotent when links are already correct")
    func idempotent() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)
        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        let expected = runtime.appendingPathComponent("bin/codevisor").path
        #expect(destination(of: bin.appendingPathComponent("codevisor")) == expected)
    }

    @Test("Repairs links pointing into another Codevisor bundle")
    func repairsOwnedLinks() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        let staleRuntime = try makeRuntime(
            in: root.appendingPathComponent("old", isDirectory: true),
            bundleName: "Codevisor.app"
        )
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: bin.appendingPathComponent("codevisor"),
            withDestinationURL: staleRuntime.appendingPathComponent("bin/codevisor")
        )

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        let expected = runtime.appendingPathComponent("bin/codevisor").path
        #expect(destination(of: bin.appendingPathComponent("codevisor")) == expected)
    }

    @Test("Repairs broken links")
    func repairsBrokenLinks() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        try fileManager.createSymbolicLink(
            at: bin.appendingPathComponent("codevisor"),
            withDestinationURL: root.appendingPathComponent("gone/codevisor")
        )

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        let expected = runtime.appendingPathComponent("bin/codevisor").path
        #expect(destination(of: bin.appendingPathComponent("codevisor")) == expected)
    }

    @Test("Leaves foreign symlinks alone")
    func keepsForeignLinks() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        // Stands in for a Homebrew-formula or user-managed link.
        try fileManager.createSymbolicLink(
            at: bin.appendingPathComponent("codevisor"),
            withDestinationURL: URL(fileURLWithPath: "/usr/bin/true")
        )

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        #expect(destination(of: bin.appendingPathComponent("codevisor")) == "/usr/bin/true")
    }

    @Test("Leaves regular files alone")
    func keepsRegularFiles() throws {
        let (root, runtime, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }
        try fileManager.createDirectory(at: bin, withIntermediateDirectories: true)
        let file = bin.appendingPathComponent("codevisor")
        try "user script".write(to: file, atomically: true, encoding: .utf8)

        CommandLineTools.ensureInstalled(runtimeDirectory: runtime, binDirectory: bin)

        #expect(destination(of: file) == nil)
        #expect(try String(contentsOf: file, encoding: .utf8) == "user script")
    }

    @Test("No-ops without a bundled runtime")
    func noRuntime() throws {
        let (root, _, bin) = try makeFixture()
        defer { try? fileManager.removeItem(at: root) }

        CommandLineTools.ensureInstalled(runtimeDirectory: nil, binDirectory: bin)

        #expect(!fileManager.fileExists(atPath: bin.path))
    }
}
