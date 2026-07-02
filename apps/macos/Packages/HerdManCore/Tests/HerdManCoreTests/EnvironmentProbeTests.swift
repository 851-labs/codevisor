import Foundation
import Testing
@testable import HerdManCore

@Suite("EnvironmentProbe")
struct EnvironmentProbeTests {
    private func makeProbe(runner: FakeCommandRunner, executables: Set<String>) -> EnvironmentProbe {
        EnvironmentProbe(
            runner: runner,
            fileProbe: FakeFileProbe(executablePaths: executables),
            loginShell: URL(fileURLWithPath: "/bin/zsh"),
            baseEnvironment: ["HOME": "/Users/test"]
        )
    }

    @Test("resolvedPath uses the login shell output and merges fallbacks")
    func resolvedPathSuccess() async {
        let runner = FakeCommandRunner(stdout: "/custom/bin\n")
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path.hasPrefix("/custom/bin"))
        // Fallback directories are appended.
        #expect(path.contains("/usr/bin"))
        // It ran the login shell with the right arguments.
        #expect(runner.invocations.first?.1 == ["-ilc", "echo $PATH"])
    }

    @Test("resolvedPath falls back when the shell fails")
    func resolvedPathFailure() async {
        let runner = FakeCommandRunner(.failure(.boom))
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path == EnvironmentProbe.fallbackPathDirectories.joined(separator: ":"))
    }

    @Test("resolvedPath falls back when the shell returns empty output")
    func resolvedPathEmpty() async {
        let runner = FakeCommandRunner(stdout: "   \n")
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path == EnvironmentProbe.fallbackPathDirectories.joined(separator: ":"))
    }

    @Test("resolvedPath falls back on non-zero exit")
    func resolvedPathNonZeroExit() async {
        let runner = FakeCommandRunner(stdout: "/x", exitCode: 1)
        let probe = makeProbe(runner: runner, executables: [])
        let path = await probe.resolvedPath()
        #expect(path == EnvironmentProbe.fallbackPathDirectories.joined(separator: ":"))
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
            .appendingPathComponent("herdman-probe-\(UUID().uuidString)")
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
