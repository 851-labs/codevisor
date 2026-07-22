import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("Session overlay, settings, import")
struct SessionOverlayTests {
    private func makeModel() -> ProjectListModel {
        ProjectListModel(
            projectRepository: DefaultProjectRepository(store: InMemoryStore()),
            sessionRepository: DefaultSessionRepository(store: InMemoryStore())
        )
    }

    @Test("Old persisted sessions decode with defaults")
    func backwardCompatible() throws {
        let json = #"{"id":"\#(UUID().uuidString)","projectId":"\#(UUID().uuidString)","title":"Legacy","createdAt":768000000}"#
        let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
        #expect(session.title == "Legacy")
        #expect(session.serverId == "local")
        #expect(session.harnessId == "")
        #expect(session.origin == .codevisor)
        #expect(session.isArchived == false)
    }

    @Test("Settings persist onboarding and import choice")
    func settings() {
        let store = InMemoryStore()
        let model = AppSettingsModel(store: store)
        #expect(model.hasCompletedOnboarding == false)
        #expect(model.shareAnalytics == false)
        #expect(model.betaUpdatesEnabled == false)
        #expect(model.settings.notificationsEnabled)
        #expect(model.settings.systemNotificationsEnabled)
        #expect(model.settings.notificationSoundsEnabled)
        model.completeOnboarding(importExternalSessions: true)
        model.setShareAnalytics(true)
        model.setBetaUpdatesEnabled(true)
        model.setChatFinishedSoundPath("/System/Library/Sounds/Ping.aiff")
        model.setActionRequiredSoundPath("/System/Library/Sounds/Hero.aiff")
        #expect(AppSettingsModel(store: store).hasCompletedOnboarding)
        #expect(AppSettingsModel(store: store).importExternalSessions)
        #expect(AppSettingsModel(store: store).shareAnalytics)
        #expect(AppSettingsModel(store: store).betaUpdatesEnabled)
        #expect(AppSettingsModel(store: store).settings.chatFinishedSoundPath.hasSuffix("Ping.aiff"))
        #expect(AppSettingsModel(store: store).settings.actionRequiredSoundPath.hasSuffix("Hero.aiff"))
    }

    @Test("Settings saved before beta updates default to the stable channel")
    func legacySettingsDefaultToStableUpdates() throws {
        let store = InMemoryStore()
        try store.saveData(
            Data(#"{"hasCompletedOnboarding":true,"shareAnalytics":true}"#.utf8),
            forKey: "settings"
        )

        #expect(!AppSettingsModel(store: store).betaUpdatesEnabled)
    }

    @Test("Importing creates projects by cwd and dedups")
    func importing() {
        let model = makeModel()
        let imported = [
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "a", cwd: "/Users/x/proj", title: "Build")),
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "b", cwd: "/Users/x/proj", title: "Fix")),
            ImportedSession(harnessId: "claude-code", info: SessionInfo(sessionId: "c", cwd: "/Users/x/other", title: "Docs"))
        ]
        model.importSessions(imported, serverId: "local")
        model.importSessions(imported, serverId: "local") // second time should not duplicate

        #expect(model.projects.count == 2)
        #expect(model.sessions.count == 3)
        #expect(model.sessions.allSatisfy { $0.origin == .imported })
        let proj = model.projects.first { $0.folderURL.path == "/Users/x/proj" }!
        #expect(model.sessions(in: proj).count == 2)
    }

    @Test("Imported sessions and their projects hide when import is off")
    func gating() {
        let model = makeModel()
        model.importSessions([
            ImportedSession(harnessId: "codex", info: SessionInfo(sessionId: "a", cwd: "/Users/x/proj", title: "Build"))
        ], serverId: "local")
        let proj = model.projects.first!

        model.showsImportedSessions = false
        #expect(model.sessions(in: proj).isEmpty)
        #expect(model.activeProjects.isEmpty) // imported-only project hidden

        model.showsImportedSessions = true
        #expect(model.sessions(in: proj).count == 1)
        #expect(model.activeProjects.count == 1)
    }

    @Test("User-added projects stay visible even when empty")
    func userProjectVisible() {
        let model = makeModel()
        model.addProject(folderURL: URL(fileURLWithPath: "/tmp/mine"))
        model.showsImportedSessions = false
        #expect(model.activeProjects.count == 1)
    }

    @Test("setAgentSessionId records the agent session id")
    func setAgentSessionId() {
        let model = makeModel()
        let ws = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        let session = model.newSession(in: ws, harnessId: "claude-code")
        #expect(session.agentSessionId == nil)
        model.setAgentSessionId("agent-123", for: session.id, serverId: session.serverId)
        #expect(model.sessions.first { $0.id == session.id }?.agentSessionId == "agent-123")
    }

    @Test("setIcon updates and persists a project symbol")
    func setIcon() {
        let model = makeModel()
        let ws = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/iconme"))
        #expect(ws.symbolName == Project.defaultSymbolName)
        model.setIcon("hammer", for: ws)
        #expect(model.projects.first { $0.id == ws.id }?.symbolName == "hammer")
    }

    @Test("removeAll clears projects and sessions")
    func removeAll() {
        let model = makeModel()
        let ws = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"))
        model.newSession(in: ws)
        model.removeAll()
        #expect(model.projects.isEmpty)
        #expect(model.sessions.isEmpty)
    }

    @Test("deleteAllData wipes data and re-triggers onboarding")
    func deleteAllData() {
        let environment = AppEnvironment.preview()
        environment.configCache.store([], forHarness: "claude-code", onServer: "local")
        environment.setBetaUpdatesEnabled(true)
        #expect(environment.settings.hasCompletedOnboarding)
        #expect(environment.appUpdate.allowsPrereleaseUpdates)
        #expect(!environment.projectList.projects.isEmpty)

        environment.deleteAllData()

        #expect(environment.projectList.projects.isEmpty)
        #expect(environment.projectList.sessions.isEmpty)
        #expect(environment.configCache.options(forHarness: "claude-code", onServer: "local").isEmpty)
        #expect(!environment.settings.hasCompletedOnboarding)
        #expect(!environment.settings.betaUpdatesEnabled)
        #expect(!environment.appUpdate.allowsPrereleaseUpdates)
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

    @Test("finishOnboarding with a project folder adds a project")
    func onboardingAddsProject() async {
        let environment = AppEnvironment.preview(seedProjects: [], hasOnboarded: false)
        let folder = URL(fileURLWithPath: "/tmp/my-project")
        let project = await environment.finishOnboarding(importExternalSessions: false, projectFolder: folder)
        #expect(environment.settings.hasCompletedOnboarding)
        #expect(project?.folderURL == folder)
        #expect(environment.projectList.projects.contains { $0.folderURL == folder })
    }

    @Test("SessionImporter fetches across ready harnesses")
    func importer() async {
        let importer = SessionImporter(harnessService: FakeImportService())
        let imported = await importer.fetchAll()
        #expect(imported.contains { $0.harnessId == "codex" && $0.info.sessionId == "s1" })
    }
}

/// A fake harness service that returns scripted sessions for import tests.
private struct FakeImportService: HarnessServicing {
    func readyHarnesses() async -> [ServerHarness] {
        [ServerHarness(
            id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
            source: "registry", launchKind: "executable", enabled: true,
            readiness: ServerHarnessReadiness(state: "ready")
        )]
    }
    func allHarnesses() async -> [ServerHarness] { await readyHarnesses() }
    func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
        [SessionInfo(sessionId: "s1", cwd: "/x", title: "T")]
    }
}
