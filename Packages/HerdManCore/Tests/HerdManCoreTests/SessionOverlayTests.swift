import Foundation
import Testing
import ACPKit
import ACPAgents
@testable import HerdManCore

@MainActor
@Suite("Session overlay, settings, import")
struct SessionOverlayTests {
    private func makeModel() -> WorkspaceListModel {
        WorkspaceListModel(
            workspaceRepository: DefaultWorkspaceRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
    }

    @Test("Old persisted sessions decode with defaults")
    func backwardCompatible() throws {
        let json = #"{"id":"\#(UUID().uuidString)","workspaceId":"\#(UUID().uuidString)","title":"Legacy","createdAt":768000000}"#
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.title == "Legacy")
        #expect(session.harnessId == "")
        #expect(session.origin == .herdman)
        #expect(session.isArchived == false)
    }

    @Test("Settings persist onboarding and import choice")
    func settings() {
        let store = InMemoryStore()
        let model = AppSettingsModel(store: store)
        #expect(model.hasCompletedOnboarding == false)
        model.completeOnboarding(importExternalSessions: true)
        #expect(AppSettingsModel(store: store).hasCompletedOnboarding)
        #expect(AppSettingsModel(store: store).importExternalSessions)
    }

    @Test("Importing creates workspaces by cwd and dedups")
    func importing() {
        let model = makeModel()
        let imported = [
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "a", cwd: "/Users/x/proj", title: "Build")),
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "b", cwd: "/Users/x/proj", title: "Fix")),
            ImportedSession(harnessId: "claude-code", info: SessionInfo(sessionId: "c", cwd: "/Users/x/other", title: "Docs"))
        ]
        model.importSessions(imported)
        model.importSessions(imported) // second time should not duplicate

        #expect(model.workspaces.count == 2)
        #expect(model.sessions.count == 3)
        #expect(model.sessions.allSatisfy { $0.origin == .imported })
        let proj = model.workspaces.first { $0.folderURL.path == "/Users/x/proj" }!
        #expect(model.sessions(in: proj).count == 2)
    }

    @Test("Imported sessions and their workspaces hide when import is off")
    func gating() {
        let model = makeModel()
        model.importSessions([
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "a", cwd: "/Users/x/proj", title: "Build"))
        ])
        let proj = model.workspaces.first!

        model.showsImportedSessions = false
        #expect(model.sessions(in: proj).isEmpty)
        #expect(model.activeWorkspaces.isEmpty) // imported-only workspace hidden

        model.showsImportedSessions = true
        #expect(model.sessions(in: proj).count == 1)
        #expect(model.activeWorkspaces.count == 1)
    }

    @Test("User-added workspaces stay visible even when empty")
    func userWorkspaceVisible() {
        let model = makeModel()
        model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/mine"))
        model.showsImportedSessions = false
        #expect(model.activeWorkspaces.count == 1)
    }

    @Test("setAgentSessionId records the agent session id")
    func setAgentSessionId() {
        let model = makeModel()
        let ws = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: ws, harnessId: "claude-code")
        #expect(session.agentSessionId == nil)
        model.setAgentSessionId("agent-123", for: session.id)
        #expect(model.sessions.first { $0.id == session.id }?.agentSessionId == "agent-123")
    }

    @Test("setIcon updates and persists a workspace symbol")
    func setIcon() {
        let model = makeModel()
        let ws = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/iconme"))
        #expect(ws.symbolName == Workspace.defaultSymbolName)
        model.setIcon("hammer", for: ws)
        #expect(model.workspaces.first { $0.id == ws.id }?.symbolName == "hammer")
    }

    @Test("removeAll clears workspaces and sessions")
    func removeAll() {
        let model = makeModel()
        let ws = model.addWorkspace(folderURL: URL(fileURLWithPath: "/tmp/a"))
        model.newSession(in: ws)
        model.removeAll()
        #expect(model.workspaces.isEmpty)
        #expect(model.sessions.isEmpty)
    }

    @Test("deleteAllData wipes data and re-triggers onboarding")
    func deleteAllData() {
        let environment = AppEnvironment.preview()
        environment.configCache.store([], forHarness: "claude-code")
        #expect(environment.settings.hasCompletedOnboarding)
        #expect(!environment.workspaceList.workspaces.isEmpty)

        environment.deleteAllData()

        #expect(environment.workspaceList.workspaces.isEmpty)
        #expect(environment.workspaceList.sessions.isEmpty)
        #expect(environment.configCache.options(forHarness: "claude-code").isEmpty)
        #expect(!environment.settings.hasCompletedOnboarding)
    }

    @Test("Harness enable/disable persists")
    func harnessEnablement() {
        let store = InMemoryStore()
        let model = AppSettingsModel(store: store)
        #expect(model.isHarnessEnabled("codex")) // enabled by default
        model.setHarness("codex", enabled: false)
        #expect(!model.isHarnessEnabled("codex"))
        // Reload from the same store to confirm persistence.
        #expect(!AppSettingsModel(store: store).isHarnessEnabled("codex"))
        model.setHarness("codex", enabled: true)
        #expect(model.isHarnessEnabled("codex"))
    }

    @Test("finishOnboarding with a project folder adds a workspace")
    func onboardingAddsProject() async {
        let environment = AppEnvironment.preview(seedWorkspaces: [], hasOnboarded: false)
        let folder = URL(fileURLWithPath: "/tmp/my-project")
        let workspace = await environment.finishOnboarding(importExternalSessions: false, projectFolder: folder)
        #expect(environment.settings.hasCompletedOnboarding)
        #expect(workspace?.folderURL == folder)
        #expect(environment.workspaceList.workspaces.contains { $0.folderURL == folder })
    }

    @Test("SessionImporter fetches across ready harnesses")
    func importer() async {
        let importer = SessionImporter(agentService: FakeImportService())
        let imported = await importer.fetchAll()
        #expect(imported.contains { $0.harnessId == "codex" && $0.info.sessionId == "s1" })
    }
}

/// A fake agent service that returns scripted sessions for import tests.
private struct FakeImportService: AgentServicing {
    func discoverAgents() async -> [DiscoveredAgent] {
        [DiscoveredAgent(id: "codex", name: "Codex", source: .registry, method: .npx, readiness: .ready)]
    }
    func launch(_ agent: DiscoveredAgent, workingDirectory: URL, delegate: (any ACPClientDelegate)?) async throws -> ACPClient {
        ACPClient(transport: MockTransport())
    }
    func listSessions(for agent: DiscoveredAgent) async throws -> [SessionInfo] {
        [SessionInfo(sessionId: "s1", cwd: "/x", title: "T")]
    }
}
