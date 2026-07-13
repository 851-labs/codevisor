import Foundation
import Testing
@testable import CodevisorCore

@Suite("EnvironmentProbe")
struct EnvironmentProbeTests {
    private static let home = "/Users/test"
    private static let fallbacks = EnvironmentProbe.fallbackPathDirectories(home: home)

    private func makeProbe(
        runner: FakeCommandRunner,
        executables: Set<String>,
        basePath: String? = nil
    ) -> EnvironmentProbe {
        var base = ["HOME": Self.home]
        if let basePath {
            base["PATH"] = basePath
        }
        return EnvironmentProbe(
            runner: runner,
            fileProbe: FakeFileProbe(executablePaths: executables),
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            baseEnvironment: base
        )
    }

    @Test("resolvedPath parses env output and merges base PATH plus fallbacks, deduped")
    func resolvedPathSuccess() async {
        let runner = FakeCommandRunner(stdout: "HOME=/Users/test\nPATH=/custom/bin:/usr/bin\nLANG=C\n")
        let probe = makeProbe(runner: runner, executables: [], basePath: "/base/only:/usr/bin")
        let path = await probe.resolvedPath()
        let directories = path.split(separator: ":").map(String.init)
        // Probed ordering wins, base PATH follows, fallbacks appended, deduped.
        #expect(Array(directories.prefix(2)) == ["/custom/bin", "/usr/bin"])
        #expect(directories.contains("/base/only"))
        #expect(directories.contains("/Users/test/.local/bin"))
        #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
        // It probed the login shell for the real environment (fish-safe).
        #expect(runner.invocations.first?.1 == ["-ilc", "/usr/bin/env"])
    }

    @Test("resolvedPath takes the last PATH line and ignores other lines")
    func resolvedPathLastLineWins() async {
        let runner = FakeCommandRunner(stdout: "PATH=/stale\nOTHER=x\nPATH=/fresh\n")
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path.hasPrefix("/fresh"))
        #expect(!path.contains("/stale"))
    }

    @Test("resolvedPath falls back when the shell fails")
    func resolvedPathFailure() async {
        let runner = FakeCommandRunner(.failure(.boom))
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path == Self.fallbacks.joined(separator: ":"))
    }

    @Test("resolvedPath keeps the base PATH when the shell output has no PATH line")
    func resolvedPathNoPathLine() async {
        let runner = FakeCommandRunner(stdout: "HOME=/Users/test\n")
        let probe = makeProbe(runner: runner, executables: [], basePath: "/base/only")
        let path = await probe.resolvedPath()
        #expect(path == (["/base/only"] + Self.fallbacks).joined(separator: ":"))
    }

    @Test("resolvedPath falls back on non-zero exit")
    func resolvedPathNonZeroExit() async {
        let runner = FakeCommandRunner(stdout: "PATH=/x", exitCode: 1)
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path == Self.fallbacks.joined(separator: ":"))
    }

    @Test("fallback directories include per-user install locations")
    func fallbackDirectories() {
        #expect(Self.fallbacks.first == "/Users/test/.local/bin")
        #expect(Self.fallbacks.contains("/opt/homebrew/bin"))
        #expect(Self.fallbacks.contains("/Users/test/.volta/bin"))
        #expect(Self.fallbacks.contains("/Users/test/.asdf/shims"))
    }

    @Test("userLoginShell returns a usable shell path")
    func loginShell() {
        // The password database always has a shell for the current user; the
        // env fallback path is exercised with an injected empty environment.
        let shell = EnvironmentProbe.userLoginShell(environment: [:])
        #expect(shell.path.hasPrefix("/"))
        #expect(!shell.path.isEmpty)
    }

    @Test("locate finds an executable on PATH")
    func locate() {
        let probe = makeProbe(runner: FakeCommandRunner(stdout: ""), executables: ["/opt/bin/npx"])
        #expect(probe.locate("npx", inPath: "/opt/bin:/usr/bin")?.path == "/opt/bin/npx")
        #expect(probe.locate("node", inPath: "/opt/bin") == nil)
    }

    @Test("locate ignores empty path components")
    func locateEmptyComponents() {
        let probe = makeProbe(runner: FakeCommandRunner(stdout: ""), executables: ["/opt/bin/x"])
        #expect(probe.locate("x", inPath: "::/opt/bin:")?.path == "/opt/bin/x")
    }

    @Test("resolvedEnvironment overrides PATH")
    func resolvedEnvironment() {
        let probe = makeProbe(runner: FakeCommandRunner(stdout: ""), executables: [])
        let environment = probe.resolvedEnvironment(path: "/a:/b")
        #expect(environment["PATH"] == "/a:/b")
        #expect(environment["HOME"] == "/Users/test")
    }

    @Test("executables lists matching files in a real directory")
    func executablesScan() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("codevisor-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let agentBinary = directory.appendingPathComponent("sample-acp")
        try "#!/bin/sh\n".write(to: agentBinary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: agentBinary.path)
        let other = directory.appendingPathComponent("not-an-agent")
        try "x".write(to: other, atomically: true, encoding: .utf8)

        let probe = EnvironmentProbe(
            runner: FakeCommandRunner(stdout: ""),
            fileProbe: DefaultFileProbe(),
            baseEnvironment: [:]
        )
        let found = probe.executables(inPath: directory.path, matching: { $0.hasSuffix("-acp") })
        #expect(found.map(\.lastPathComponent) == ["sample-acp"])
    }
}
