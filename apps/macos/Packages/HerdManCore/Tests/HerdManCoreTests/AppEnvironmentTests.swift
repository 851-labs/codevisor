import Foundation
import Testing
import ACPKit
import ACPAgents
@testable import HerdManCore

@MainActor
@Suite("AppEnvironment and AgentService")
struct AppEnvironmentTests {
    @Test("Debug builds use isolated development defaults")
    func debugVariantDefaults() {
        #if DEBUG
        #expect(HerdManAppVariant.isDevelopment)
        #expect(HerdManAppVariant.localServerPort == HerdManAppVariant.developmentPort)
        #expect(HerdManAppVariant.applicationSupportDirectoryName == "HerdMan Development")
        #else
        #expect(!HerdManAppVariant.isDevelopment)
        #expect(HerdManAppVariant.localServerPort == HerdManAppVariant.productionPort)
        #expect(HerdManAppVariant.applicationSupportDirectoryName == "HerdMan")
        #endif
    }

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

    @Test("Onboarding with a project folder imports that folder's existing sessions")
    func onboardingImportsProjectSessions() async {
        let environment = AppEnvironment.preview(seedWorkspaces: [], hasOnboarded: false)

        // PreviewAgentService reports the "ext-1" session in
        // /Users/me/src/website for each of its two ready harnesses.
        let workspace = await environment.finishOnboarding(
            projectFolder: URL(fileURLWithPath: "/Users/me/src/website")
        )

        #expect(environment.settings.hasCompletedOnboarding)
        #expect(environment.settings.importExternalSessions)
        #expect(environment.workspaceList.showsImportedSessions)
        let imported = environment.workspaceList.sessions(in: workspace)
        #expect(imported.count == 2)
        #expect(imported.allSatisfy { $0.agentSessionId == "ext-1" && $0.origin == .imported })
        #expect(Set(imported.map(\.harnessId)) == ["claude-code", "codex"])
    }

    @Test("Importable sessions are scoped to the folder and exclude known ones")
    func importableSessionsScopedToFolder() async {
        let environment = AppEnvironment.preview(seedWorkspaces: [])

        let found = await environment.findImportableSessions(
            for: URL(fileURLWithPath: "/Users/me/src/website")
        )
        #expect(found.map(\.info.sessionId) == ["ext-1", "ext-1"])
        #expect(found.allSatisfy { $0.info.cwd == "/Users/me/src/website" })

        // Once imported, the same discovery is no longer offered.
        let workspace = environment.workspaceList.addWorkspace(
            folderURL: URL(fileURLWithPath: "/Users/me/src/website")
        )
        environment.importSessions(found, into: workspace)
        #expect(environment.settings.importExternalSessions)
        let remaining = await environment.findImportableSessions(
            for: URL(fileURLWithPath: "/Users/me/src/website")
        )
        #expect(remaining.isEmpty)
    }

    @Test("Workspace recommendations come from recent harness sessions")
    func workspaceRecommendations() async {
        let environment = AppEnvironment.preview(seedWorkspaces: [])

        // PreviewAgentService's sessions live in folders that don't exist on
        // the test machine, so the default directory filter drops them.
        let recommendations = await environment.recommendedWorkspaces()

        #expect(recommendations.isEmpty)
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
