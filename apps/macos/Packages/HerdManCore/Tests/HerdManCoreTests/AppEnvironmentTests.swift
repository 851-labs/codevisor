import Foundation
import Testing
import ACPKit
import ACPAgents
@testable import HerdManCore

@MainActor
@Suite("AppEnvironment and AgentService")
struct AppEnvironmentTests {
    @Test("Preview environment seeds sample workspaces")
    func previewSeed() {
        let environment = AppEnvironment.preview()
        #expect(environment.workspaceList.workspaces.count == AppEnvironment.sampleWorkspaces.count)
        #expect(environment.workspaceList.hasArchivedWorkspaces)
    }

    @Test("Preview environment can use a custom seed")
    func customSeed() {
        let environment = AppEnvironment.preview(seedWorkspaces: [])
        #expect(environment.workspaceList.workspaces.isEmpty)
    }

    @Test("Preview agent service returns sample agents and launches a client")
    func previewAgentService() async throws {
        let service = PreviewAgentService()
        let agents = await service.discoverAgents()
        #expect(agents.contains { $0.id == "claude-code" })
        // Launch returns a constructed client over a mock transport.
        let client = try await service.launch(
            agents[0],
            workingDirectory: URL(fileURLWithPath: "/tmp"),
            delegate: nil
        )
        await client.close()
    }

    @Test("AgentService surfaces installed harnesses only")
    func agentServiceDiscovery() async {
        // claude + npx present -> the Claude Code harness is installed; codex absent.
        let probe = EnvironmentProbe(
            runner: StubRunner(),
            fileProbe: StubProbe(installed: ["/usr/bin/claude", "/usr/bin/npx"]),
            baseEnvironment: [:]
        )
        let service = AgentService(discovery: HarnessDiscovery(probe: probe))
        let agents = await service.discoverAgents()
        #expect(agents.contains { $0.id == "claude-code" })
        #expect(!agents.contains { $0.id == "codex" })
    }
}

private struct StubRunner: CommandRunner {
    func run(executableURL: URL, arguments: [String], environment: [String: String]?) async throws -> CommandResult {
        CommandResult(standardOutput: "/usr/bin", standardError: "", exitCode: 0)
    }
}

private struct StubProbe: FileProbing {
    let installed: Set<String>
    func isExecutableFile(atPath path: String) -> Bool { installed.contains(path) }
}
