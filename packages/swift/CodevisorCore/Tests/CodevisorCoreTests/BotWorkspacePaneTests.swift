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

  @Test("Closing a pane the server holds in a bot's workspace removes it there too, so it cannot come back")
  func closingAServerPaneTellsTheServer() async throws {
    var tabbed = workspace
    tabbed.mainSessionId = chat.id
    tabbed.centerTabs += [WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id)))]
    let fixture = NavigationFixture()
    await fixture.install(sessions: [chat], workspaces: [tabbed])
    fixture.store.keepPanesOnDevice(in: [workspace.id])

    fixture.workspaceSync.closePaneLocally(id: terminal.id, workspaceId: workspace.id, repository: fixture.workspaces)

    #expect(paneIds(in: fixture) == [chatPaneId])
    #expect(fixture.store.pendingIntents.map(\.intent) == [.closePane(paneId: terminal.id, workspaceId: workspace.id)])
  }

  @Test("Closing a pane that only this device holds in a bot's workspace sends nothing")
  func closingADeviceOnlyPaneStaysLocal() async throws {
    let fixture = try await splitBotWorkspace()

    fixture.workspaceSync.closePaneLocally(id: terminal.id, workspaceId: workspace.id, repository: fixture.workspaces)

    #expect(paneIds(in: fixture) == [chatPaneId])
    #expect(fixture.store.pendingIntents.isEmpty)
  }

  @Test("A pane opened beside a bot is sent to a server that takes a bot's panes")
  func openedPaneIsSent() async throws {
    let fixture = try await sharedBotWorkspace()

    try open(terminal, in: fixture)

    #expect(fixture.store.pendingIntents.map(\.intent) == [.upsertPane(terminal, workspaceId: workspace.id)])
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])
  }

  @Test("A pane another device opens beside a bot shows here as a split, and leaves when that device closes it")
  func otherDevicePanesFollowTheServer() async throws {
    let fixture = try await sharedBotWorkspace()
    var opened = workspace
    opened.centerTabs += [WorkspaceTab(root: .leaf(PaneGroupState(panes: [terminal], selectedPaneId: terminal.id)))]

    await fixture.store.replace(
      .fixture(sessions: [chat], workspaces: [opened], cursor: 2), machineId: "local", requestedAt: Date())

    #expect(fixture.workspaces.workspace(id: workspace.id)?.centerTabs.count == 1)
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])

    await fixture.store.replace(snapshot(cursor: 3), machineId: "local", requestedAt: Date())

    #expect(paneIds(in: fixture) == [chatPaneId])
  }

  @Test("Panes a bot kept on this device are sent once its server takes them, and stay open meanwhile")
  func devicePanesAreSentOnce() async throws {
    let fixture = try await splitBotWorkspace()

    fixture.store.sharePanes(in: [workspace.id])

    #expect(fixture.store.pendingIntents.map(\.intent) == [.upsertPane(terminal, workspaceId: workspace.id)])
    #expect(paneIds(in: fixture) == [chatPaneId, terminal.id])

    fixture.store.sharePanes(in: [workspace.id])

    #expect(fixture.store.pendingIntents.count == 1)
  }

  @Test("Another agent's chat opened beside a bot stays on this device")
  func otherChatsStayOnDevice() async throws {
    let fixture = try await sharedBotWorkspace()
    let other = PaneDescriptorState(
      id: UUID(), kind: .chat, name: "Agent", terminalKey: "a", chatSessionId: UUID())

    try open(other, in: fixture)
    await fixture.store.replace(snapshot(cursor: 2), machineId: "local", requestedAt: Date())

    #expect(fixture.store.pendingIntents.isEmpty)
    #expect(paneIds(in: fixture) == [chatPaneId, other.id])
  }

  private var chatPaneId: UUID? { workspace.allPanes.first?.id }

  private func sharedBotWorkspace() async throws -> NavigationFixture {
    let fixture = NavigationFixture()
    await fixture.install(sessions: [chat], workspaces: [workspace])
    fixture.store.sharePanes(in: [workspace.id])
    return fixture
  }

  private func open(_ pane: PaneDescriptorState, in fixture: NavigationFixture) throws {
    var split = try #require(fixture.workspaces.workspace(id: workspace.id))
    _ = split.insertPane(pane, besidePane: try #require(chatPaneId), destination: .split(.trailing))
    fixture.workspaces.save(split)
    fixture.workspaceSync.publishPane(pane, workspaceId: workspace.id)
  }

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
