import Foundation
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Bot workspace panes")
struct BotWorkspacePaneTests {
  let chat: ChatSession
  let workspace: Workspace
  let terminal = PaneDescriptorState(id: UUID(), kind: .terminal, name: "Terminal", terminalKey: "t")

  init() {
    chat = ChatSession(projectId: UUID(), harnessId: "codex", title: "Helper")
    workspace = Workspace(
      name: "Helper", rootDirectory: "/tmp/helper", serverId: "local", projectId: chat.projectId,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: chat.id)))], isServerSynced: true)
  }

  @Test("A bot's own workspace keeps its split panes on this device: they are never sent and survive a snapshot")
  func splitPanesStayOnDevice() async throws {
    let fixture = try await splitBotWorkspace()

    await fixture.store.replace(snapshot(cursor: 2), machineId: "local", requestedAt: Date())

    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])
    #expect(fixture.workspaces.workspace(id: workspace.id)?.centerTabs.count == 1)
  }

  @Test("A bot's split panes survive a relaunch whose first snapshot arrives before the bot list")
  func splitPanesSurviveRelaunch() async throws {
    let fixture = try await splitBotWorkspace()
    PersistenceEncoding.drain()

    let relaunched = NavigationFixture(persistence: fixture.persistence)
    await relaunched.store.replace(snapshot(cursor: 2), machineId: "local", requestedAt: Date())

    #expect(paneIds(in: relaunched) == [chatPaneId, terminal.id])
  }

  private var chatPaneId: UUID? { workspace.allPanes.first?.id }

  private func splitBotWorkspace() async throws -> NavigationFixture {
    let fixture = NavigationFixture()
    await fixture.install(sessions: [chat], workspaces: [workspace])
    fixture.store.keepPanesOnDevice(in: [workspace.id])

    var split = try #require(fixture.workspaces.workspace(id: workspace.id))
    _ = split.insertPane(terminal, besidePane: try #require(chatPaneId), destination: .split(.trailing))
    fixture.workspaces.save(split)
    fixture.workspaceSync.publishPane(terminal, workspaceId: workspace.id)
    return fixture
  }

  private func snapshot(cursor: Int) -> ServerNavigationSnapshot {
    .fixture(sessions: [chat], workspaces: [workspace], cursor: cursor)
  }

  private func paneIds(in fixture: NavigationFixture) -> [UUID?] {
    fixture.workspaces.workspace(id: workspace.id)?.allPanes.map(\.id) ?? []
  }
}
