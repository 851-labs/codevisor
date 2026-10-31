import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("Session overlay, settings, import")
struct SessionOverlayTests {
  private func makeModel() -> ProjectListModel {
    NavigationFixture().projectList
  }

  @Test("Old persisted sessions decode with defaults")
  func backwardCompatible() throws {
    let json =
      #"{"id":"\#(UUID().uuidString)","projectId":"\#(UUID().uuidString)","title":"Legacy","createdAt":768000000}"#
    let session = try JSONDecoder().decode(ChatSession.self, from: Data(json.utf8))
    #expect(session.title == "Legacy")
    #expect(session.serverId == "local")
    #expect(session.harnessId == "")
    #expect(session.origin == .codevisor)
  }

  @Test("Settings persist onboarding and import choice")
  func settings() {
    let store = InMemoryStore()
    let model = AppSettingsModel(store: store)
    #expect(model.hasCompletedOnboarding == false)
    #expect(model.shareAnalytics == false)
    #expect(model.shareCrashReports == false)
    #expect(model.alphaUpdatesEnabled == false)
    #expect(model.settings.notificationsEnabled)
    #expect(model.settings.systemNotificationsEnabled)
    #expect(model.settings.notificationSoundsEnabled)
    model.completeOnboarding(importExternalSessions: true)
    model.setShareAnalytics(true)
    model.setShareCrashReports(true)
    model.setAlphaUpdatesEnabled(true)
    model.setChatFinishedSoundPath("/System/Library/Sounds/Ping.aiff")
    model.setActionRequiredSoundPath("/System/Library/Sounds/Hero.aiff")
    #expect(AppSettingsModel(store: store).hasCompletedOnboarding)
    #expect(AppSettingsModel(store: store).importExternalSessions)
    #expect(AppSettingsModel(store: store).shareAnalytics)
    #expect(AppSettingsModel(store: store).shareCrashReports)
    #expect(AppSettingsModel(store: store).alphaUpdatesEnabled)
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

    #expect(!AppSettingsModel(store: store).alphaUpdatesEnabled)
    #expect(!AppSettingsModel(store: store).shareCrashReports)
  }

  @Test("Imported sessions and their projects hide when import is off")
  func gating() async {
    let fixture = NavigationFixture()
    let model = fixture.projectList
    let proj = Project.fromFolder(URL(fileURLWithPath: "/Users/x/proj"), origin: .imported)
    await fixture.install(
      projects: [proj],
      sessions: [ChatSession(projectId: proj.id, harnessId: "codex", title: "Build", origin: .imported)]
    )

    model.showsImportedSessions = false
    #expect(model.fleetSessions(in: proj).isEmpty)
    #expect(model.fleetActiveProjects.isEmpty)

    model.showsImportedSessions = true
    #expect(model.fleetSessions(in: proj).count == 1)
    #expect(model.fleetActiveProjects.count == 1)
  }

  @Test("User-added projects stay visible even when empty")
  func userProjectVisible() {
    let model = makeModel()
    model.addProject(folderURL: URL(fileURLWithPath: "/tmp/mine"), serverId: "local")
    model.showsImportedSessions = false
    #expect(model.fleetActiveProjects.count == 1)
  }

  @Test("setAgentSessionId records the agent session id")
  func setAgentSessionId() {
    let model = makeModel()
    let ws = model.addProject(folderURL: URL(fileURLWithPath: "/tmp/a"), serverId: "local")
    let session = model.newSession(in: ws, harnessId: "claude-code")
    #expect(session.agentSessionId == nil)
    model.setAgentSessionId("agent-123", for: session.id, serverId: session.serverId)
    #expect(model.sessions.first { $0.id == session.id }?.agentSessionId == "agent-123")
  }

  @Test("deleteAllData wipes data and re-triggers onboarding")
  func deleteAllData() {
    let environment = AppEnvironment.preview()
    environment.configCache.store([], forHarness: "claude-code", onServer: "local")
    environment.setAlphaUpdatesEnabled(true)
    #expect(environment.settings.hasCompletedOnboarding)
    #expect(environment.appUpdate.allowsAlphaUpdates)
    #expect(!environment.projectList.projects.isEmpty)

    environment.deleteAllData()

    #expect(environment.projectList.projects.isEmpty)
    #expect(environment.projectList.sessions.isEmpty)
    #expect(environment.configCache.options(forHarness: "claude-code", onServer: "local").isEmpty)
    #expect(!environment.settings.hasCompletedOnboarding)
    #expect(!environment.settings.alphaUpdatesEnabled)
    #expect(!environment.appUpdate.allowsAlphaUpdates)
  }

  @Test("SessionImporter fetches across ready harnesses")
  func importer() async {
    let importer = SessionImporter(harnessService: FakeImportService())
    let imported = await importer.fetchAll()
    #expect(imported.contains { $0.harnessId == "codex" && $0.info.sessionId == "s1" })
  }
}

private struct FakeImportService: HarnessServicing {
  func readyHarnesses() async -> [ServerHarness] {
    [
      ServerHarness(
        id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry", launchKind: "executable", enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      )
    ]
  }
  func allHarnesses() async -> [ServerHarness] { await readyHarnesses() }
  func listSessions(forHarnessId harnessId: String) async throws -> [SessionInfo] {
    [SessionInfo(sessionId: "s1", cwd: "/x", title: "T")]
  }
}
