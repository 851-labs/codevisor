import Foundation
import Testing
@testable import ACPAgents
import ACPKit

@Suite("HarnessDiscovery")
struct HarnessDiscoveryTests {
    private func probe(executables: Set<String>, path: String = "/bin") -> EnvironmentProbe {
        EnvironmentProbe(
            runner: FakeCommandRunner(stdout: path),
            fileProbe: FakeFileProbe(executablePaths: executables),
            baseEnvironment: [:]
        )
    }

    @Test("Installed CLI with npx yields a ready npx launch spec")
    func claudeInstalled() async {
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/claude", "/bin/npx"]))
        let agents = await discovery.installed()
        let claude = agents.first { $0.id == "claude-code" }
        #expect(claude != nil)
        #expect(claude?.readiness == .ready)
        #expect(claude?.method == .npx)
        #expect(claude?.launchSpec?.executableURL.path == "/bin/npx")
        #expect(claude?.launchSpec?.arguments.first == "-y")
        #expect(claude?.launchSpec?.arguments.contains { $0.contains("claude-agent-acp") } == true)
        #expect(claude?.symbolName == "sparkle")
    }

    @Test("Missing CLI is not surfaced")
    func notInstalled() async {
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/npx"]))
        let agents = await discovery.installed()
        #expect(agents.isEmpty)
    }

    @Test("Installed CLI without npx is not launchable")
    func cliWithoutRunner() async {
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/codex"]))
        let agents = await discovery.installed()
        #expect(agents.isEmpty)
    }

    @Test("Multiple installed harnesses are all returned")
    func multiple() async {
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/claude", "/bin/codex", "/bin/npx"]))
        let ids = await discovery.installed().map(\.id)
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("codex"))
    }

    @Test("A binaryOnPath harness resolves to an executable launch")
    func binaryHarness() async {
        let custom = [HarnessDefinition(
            id: "custom",
            name: "Custom",
            symbolName: "gear",
            detectBinaries: ["custom-acp"],
            launch: .binaryOnPath(name: "custom-acp", args: ["serve"])
        )]
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/custom-acp"]), catalog: custom)
        let agent = await discovery.installed().first
        #expect(agent?.method == .executable)
        #expect(agent?.launchSpec?.arguments == ["serve"])
    }

    @Test("Adapter binaries on PATH are discovered generically")
    func pathScan() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdman-harness-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("acme-acp")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let probe = EnvironmentProbe(
            runner: FakeCommandRunner(stdout: directory.path),
            fileProbe: DefaultFileProbe(),
            baseEnvironment: [:]
        )
        let discovery = HarnessDiscovery(probe: probe, catalog: [])
        let agents = await discovery.installed()
        #expect(agents.contains { $0.name == "acme-acp" && $0.method == .executable })
    }

    @Test("Catalog includes the expected default harnesses")
    func catalog() {
        let ids = HarnessCatalog.known.map(\.id)
        #expect(ids.contains("claude-code"))
        #expect(ids.contains("codex"))
        #expect(ids.contains("opencode"))
        #expect(ids.contains("gemini"))
    }

    @Test("discoverAll surfaces installed and not-installed harnesses")
    func discoverAll() async {
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/claude", "/bin/npx"]))
        let all = await discovery.discoverAll()
        // Every catalog harness is represented.
        #expect(all.count >= HarnessCatalog.known.count)
        let claude = all.first { $0.id == "claude-code" }
        #expect(claude?.readiness == .ready)
        // Codex CLI is absent -> present but unavailable, with a reason and no spec.
        let codex = all.first { $0.id == "codex" }
        #expect(codex?.readiness.isReady == false)
        #expect(codex?.readiness.detail != nil)
        #expect(codex?.launchSpec == nil)
    }

    @Test("An installed binary harness without its CLI is unavailable")
    func binaryNotInstalled() async {
        // npx is present but opencode (a binaryOnPath harness) is not.
        let discovery = HarnessDiscovery(probe: probe(executables: ["/bin/npx"]))
        let opencode = await discovery.discoverAll().first { $0.id == "opencode" }
        #expect(opencode?.readiness == .unavailable("Not installed"))
    }
}
