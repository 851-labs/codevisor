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

  @Test("Tabs a bot's workspace had from before become splits after its conversation's; empty New Tabs go")
  func earlierTabsBecomeSplits() async throws {
    var tabbed = workspace
    let terminalTab = WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id)))
    tabbed.mainSessionId = chat.id
    tabbed.centerTabs = [terminalTab] + tabbed.centerTabs + [.placeholder()]
    tabbed.selectedCenterTabId = terminalTab.id
    let fixture = NavigationFixture()
    await fixture.install(sessions: [chat], workspaces: [tabbed])

    fixture.store.keepPanesOnDevice(in: [workspace.id])

    let folded = try #require(fixture.workspaces.workspace(id: workspace.id))
    #expect(folded.centerTabs.count == 1)
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])
    #expect(folded.selectedCenterTab?.activeLeafId == terminalTab.activeLeafId)
    #expect(fixture.store.layouts.layout(for: workspace.id)?.tabs.count == 1)
  }

  @Test("A tab saved into a bot's workspace lands as a split beside its conversation")
  func savedTabBecomesSplit() async throws {
    let fixture = NavigationFixture()
    await fixture.install(sessions: [chat], workspaces: [workspace])
    fixture.store.keepPanesOnDevice(in: [workspace.id])

    var tabbed = try #require(fixture.workspaces.workspace(id: workspace.id))
    _ = tabbed.insertPane(terminal, besidePane: try #require(chatPaneId), destination: .foregroundTab)
    fixture.workspaces.save(tabbed)

    #expect(fixture.workspaces.workspace(id: workspace.id)?.centerTabs.count == 1)
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])
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
