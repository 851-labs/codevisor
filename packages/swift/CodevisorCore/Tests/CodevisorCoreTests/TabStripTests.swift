import CodevisorClient
import Foundation
import Testing

@testable import CodevisorCore

struct TabStripTests {
  private let chatPane = UUID()
  private let terminalPane = UUID()
  private let browserPane = UUID()
  private let session = UUID()
  private let tabs: [WorkspaceTab]

  init() {
    tabs = [
      WorkspaceTab(root: .leaf(.centerInitial(sessionId: session, paneId: chatPane))),
      Self.tab(terminalPane), Self.tab(browserPane),
    ]
  }

  private static func tab(_ paneId: UUID) -> WorkspaceTab {
    WorkspaceTab(
      root: .leaf(
        PaneGroupState(
          panes: [PaneDescriptorState(id: paneId, kind: .terminal, name: "zsh", terminalKey: paneId.uuidString)],
          selectedPaneId: paneId)))
  }

  private func group(_ id: UUID, _ title: String) -> TabStripGroup {
    TabStripGroup(workspaceId: id, title: title, status: .working, collapsed: false, tabs: [])
  }

  private var positions: [UUID: String] {
    [chatPane: "0000000000011", terminalPane: "0000000000013", browserPane: "0000000000015"]
  }

  @Test("Subagent groups sit among the tabs by their keys; unplaced groups go last")
  func interleaves() {
    let tests = UUID()
    let docs = UUID()
    let later = UUID()
    let entries = TabStrip.entries(
      tabs: tabs, positions: positions,
      groups: [
        (group(docs, "docs"), "0000000000014"), (group(tests, "tests"), "0000000000012"),
        (group(later, "later"), nil),
      ])
    #expect(
      entries.map(\.id) == [tabs[0].id, tests, tabs[1].id, docs, tabs[2].id, later])
  }

  @Test("Moving a group or a tab changes only its own keys, as every device will sort them")
  func moves() {
    let tests = UUID()
    let current = TabStrip.entries(tabs: tabs, positions: positions, groups: [(group(tests, "tests"), "0000000000012")])
    // Drag the group to the end.
    var desired = current
    desired.append(desired.remove(at: 1))
    let moves = TabStrip.moves(for: desired, positions: positions, groupPositions: [tests: "0000000000012"])
    #expect(moves.count == 1)
    guard case let .group(workspaceId, position) = moves.first else {
      Issue.record("expected a group move")
      return
    }
    #expect(workspaceId == tests)
    #expect(position > "0000000000015")
    // Drag the browser tab to the front.
    var reordered = current
    reordered.insert(reordered.remove(at: 3), at: 0)
    let tabMoves = TabStrip.moves(for: reordered, positions: positions, groupPositions: [tests: "0000000000012"])
    #expect(tabMoves.count == 1)
    if case let .pane(paneId, position) = tabMoves.first {
      #expect(paneId == browserPane)
      #expect(position < "0000000000011")
    }
    #expect(TabStrip.moves(for: current, positions: positions, groupPositions: [tests: "0000000000012"]).isEmpty)
  }

  @Test("The tab with the agent's own chat can't be closed; the rest can")
  func closability() {
    var parent = ChatSession(projectId: UUID(), createdAt: Date(timeIntervalSince1970: 1))
    parent = ChatSession(id: session, projectId: parent.projectId, createdAt: parent.createdAt)
    var helper = ChatSession(projectId: parent.projectId, createdAt: Date(timeIntervalSince1970: 2))
    helper.parentSessionId = session
    var all = tabs
    all.append(WorkspaceTab(root: .leaf(.centerInitial(sessionId: helper.id))))
    let workspace = Workspace(
      name: "w", rootDirectory: nil, serverId: "local", projectId: parent.projectId, centerTabs: all)
    let home = TabStrip.homeChatId(of: workspace, sessions: [helper, parent])
    #expect(home == session)
    #expect(all.map { TabStrip.isClosable($0, homeChatId: home) } == [false, true, true, true])
    #expect(TabStrip.isClosable(all[0], homeChatId: nil))
  }

  @Test("The store shows a workspace's subagents as groups and publishes strip moves")
  @MainActor
  func storeStrip() async {
    let fixture = NavigationFixture()
    let project = Project(id: UUID(), serverId: "local", name: "p")
    var parent = Workspace(
      name: "orchestrator", rootDirectory: nil, serverId: "local", projectId: project.id, centerTabs: tabs,
      isServerSynced: true)
    parent.sidebarPosition = nil
    var child = Workspace(
      name: "tests", rootDirectory: nil, serverId: "local", projectId: project.id,
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: UUID())))], isServerSynced: true)
    child.parentWorkspaceId = parent.id
    child.parentTabPosition = "ffffffffffff8"
    child.groupCollapsed = true
    let chat = ChatSession(id: session, projectId: project.id)
    let childChat = ChatSession(id: child.chatSessionIds[0], projectId: project.id, title: "Write tests")
    for workspace in [parent, child] {
      fixture.store.layouts.setLayout(DeviceLayout(workspace), for: workspace.id)
    }
    var snapshot = ServerNavigationSnapshot.fixture(
      projects: [project], sessions: [chat, childChat], workspaces: [parent, child])
    for index in snapshot.panes.indices {
      snapshot.panes[index].position = UUID(uuidString: snapshot.panes[index].id).flatMap { positions[$0] }
    }
    await fixture.store.replace(snapshot, machineId: "local", requestedAt: Date())
    let installed = fixture.store.projection.workspacesById[parent.id]!
    let strip = fixture.store.tabStrip(for: installed)
    #expect(strip.last?.id == child.id)
    // Named like the sidebar names the agent: after its own chat.
    if case let .group(group) = strip.last { #expect(group.collapsed && group.title == "Write tests") }
    #expect(fixture.store.homeChatId(of: installed) == session)
    // Chats in an owned workspace are subagents; the orchestrator's own isn't.
    #expect(fixture.store.isSubagent(sessionId: childChat.id, serverId: "local"))
    #expect(!fixture.store.isSubagent(sessionId: childChat.id, serverId: "elsewhere"))
    #expect(!fixture.store.isSubagent(sessionId: session, serverId: "local"))
    #expect(!fixture.store.isSubagent(sessionId: UUID(), serverId: "local"))

    var desired = strip
    desired.insert(desired.removeLast(), at: 0)
    fixture.store.publishTabStripOrder(of: installed, entries: desired)
    #expect(fixture.store.tabStrip(for: installed).first?.id == child.id)
    #expect(
      fixture.store.pendingIntents.contains {
        if case .updateWorkspaceHierarchy(child.id, .groupPosition) = $0.intent { return true }
        return false
      })
  }
}
