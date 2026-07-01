import Foundation
import Testing
@testable import ACPAgents
import ACPKit

@Suite("AgentDiscovery")
struct AgentDiscoveryTests {
    private let platform = "darwin-aarch64"

    private func probe(executables: Set<String>, path: String) -> EnvironmentProbe {
        EnvironmentProbe(
            runner: FakeCommandRunner(stdout: path),
            fileProbe: FakeFileProbe(executablePaths: executables),
            baseEnvironment: [:]
        )
    }

    private func manifest(_ distribution: AgentDistribution, id: String = "agent") -> AgentManifest {
        AgentManifest(id: id, name: id.capitalized, distribution: distribution)
    }

    @Test("npx manifest resolves to a ready npx launch spec")
    func npxReady() {
        let discovery = AgentDiscovery(probe: probe(executables: ["/bin/npx"], path: "/bin"), platformKey: platform)
        let agent = discovery.resolve(
            manifest: manifest(AgentDistribution(npx: NpxDistribution(package: "@x/acp", args: ["--foo"], env: ["E": "1"]))),
            path: "/bin",
            environment: ["PATH": "/bin"]
        )
        #expect(agent.readiness == .ready)
        #expect(agent.method == .npx)
        #expect(agent.launchSpec?.executableURL.path == "/bin/npx")
        #expect(agent.launchSpec?.arguments == ["-y", "@x/acp", "--foo"])
        #expect(agent.launchSpec?.environment["E"] == "1")
    }

    @Test("npx manifest without npx needs the runner")
    func npxMissing() {
        let discovery = AgentDiscovery(probe: probe(executables: [], path: "/bin"), platformKey: platform)
        let agent = discovery.resolve(
            manifest: manifest(AgentDistribution(npx: NpxDistribution(package: "p"))),
            path: "/bin",
            environment: [:]
        )
        #expect(agent.readiness == .needsRunner("npx"))
        #expect(agent.launchSpec == nil)
    }

    @Test("uvx manifest resolves and reports missing runner")
    func uvx() {
        let ready = AgentDiscovery(probe: probe(executables: ["/bin/uvx"], path: "/bin"), platformKey: platform)
        let agent = ready.resolve(
            manifest: manifest(AgentDistribution(uvx: UvxDistribution(package: "pyagent", args: ["-q"]))),
            path: "/bin",
            environment: ["PATH": "/bin"]
        )
        #expect(agent.method == .uvx)
        #expect(agent.readiness == .ready)
        #expect(agent.launchSpec?.arguments == ["pyagent", "-q"])

        let missing = AgentDiscovery(probe: probe(executables: [], path: "/bin"), platformKey: platform)
        let missingAgent = missing.resolve(
            manifest: manifest(AgentDistribution(uvx: UvxDistribution(package: "pyagent"))),
            path: "/bin",
            environment: [:]
        )
        #expect(missingAgent.readiness == .needsRunner("uvx"))
    }

    @Test("Installed platform binary resolves to ready")
    func binaryInstalled() {
        let discovery = AgentDiscovery(probe: probe(executables: ["/bin/agent-bin"], path: "/bin"), platformKey: platform)
        let agent = discovery.resolve(
            manifest: manifest(AgentDistribution(binary: [platform: BinaryDistribution(cmd: "agent-bin", args: ["serve"])])),
            path: "/bin",
            environment: ["PATH": "/bin"]
        )
        #expect(agent.method == .binary)
        #expect(agent.readiness == .ready)
        #expect(agent.launchSpec?.arguments == ["serve"])
    }

    @Test("Uninstalled platform binary is unavailable")
    func binaryMissing() {
        let discovery = AgentDiscovery(probe: probe(executables: [], path: "/bin"), platformKey: platform)
        let agent = discovery.resolve(
            manifest: manifest(AgentDistribution(binary: [platform: BinaryDistribution(cmd: "agent-bin")])),
            path: "/bin",
            environment: [:]
        )
        #expect(agent.readiness == .unavailable("Binary not installed"))
    }

    @Test("Manifest with no compatible distribution is unavailable")
    func noDistribution() {
        let discovery = AgentDiscovery(probe: probe(executables: [], path: "/bin"), platformKey: platform)
        let agent = discovery.resolve(
            manifest: manifest(AgentDistribution()),
            path: "/bin",
            environment: [:]
        )
        #expect(agent.readiness == .unavailable("No compatible distribution"))
    }

    @Test("discover scans PATH for *-acp binaries and dedups registry entries")
    func discoverWithPathScan() async throws {
        // Real temp dir with an extra ACP binary.
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("herdman-disc-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let binary = directory.appendingPathComponent("extra-acp")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let probe = EnvironmentProbe(
            runner: FakeCommandRunner(stdout: directory.path),
            fileProbe: DefaultFileProbe(),
            baseEnvironment: [:]
        )
        let discovery = AgentDiscovery(probe: probe, platformKey: platform)
        // Registry has one npx agent (npx not present in temp dir, so needsRunner).
        let registry = AgentRegistry(agents: [manifest(AgentDistribution(npx: NpxDistribution(package: "p")), id: "reg")])
        let agents = await discovery.discover(from: registry)

        #expect(agents.contains { $0.id == "reg" })
        let pathAgent = agents.first { $0.source == .path }
        #expect(pathAgent?.name == "extra-acp")
        #expect(pathAgent?.readiness == .ready)
        #expect(pathAgent?.method == .executable)
    }

    @Test("currentPlatformKey reflects the host architecture")
    func platformKey() {
        #expect(AgentDiscovery.currentPlatformKey.hasPrefix("darwin-"))
    }
}
