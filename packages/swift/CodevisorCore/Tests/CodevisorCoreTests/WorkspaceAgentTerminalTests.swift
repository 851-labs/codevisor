import Foundation
import Testing
@testable import CodevisorCore

@Suite("Workspace agent terminals")
struct WorkspaceAgentTerminalTests {
  private let owner = UUID()
  private let otherOwner = UUID()

  private func workspace() -> Workspace {
    Workspace(
      name: "Example", rootDirectory: "/example", serverId: "local", projectId: UUID(),
      centerTree: .leaf(.centerInitial(sessionId: owner)), createdAt: Date(timeIntervalSince1970: 0)
    )
  }

  @Test("Agent tasks create ordinary tabs without changing selection or duplicating terminals")
  func createAndRepeat() throws {
    var workspace = workspace()
    let selected = workspace.selectedCenterTabId
    let tasks = [(terminalKey: "agent-key", name: "dev server")]
    let changes = workspace.syncAgentTerminals(tasks + tasks, owner: owner, pruneEnded: true)
    let pane = try #require(changes.updated.first)
    #expect(changes.updated.count == 1)
    #expect(changes.removed.isEmpty)
    #expect(workspace.allPanes.count == 2)
    #expect(workspace.tabId(containingPane: pane.id) != nil)
    #expect(pane.terminalKey == "agent-key")
    #expect(pane.isAgentTerminal)
    #expect(pane.ownerChatSessionId == owner)
    #expect(workspace.selectedCenterTabId == selected)
    let repeated = workspace.syncAgentTerminals(tasks, owner: owner, pruneEnded: true)
    #expect(repeated.isEmpty)
    #expect(workspace.allPanes.last?.id == pane.id)
  }

  @Test("Snapshots prune only the owning chat's terminals after the first snapshot")
  func scopedPruning() throws {
    var workspace = workspace()
    let selected = workspace.selectedCenterTabId
    let user = PaneGroupState.initial(sessionId: owner).panes[0]
    workspace.upsertCenterPane(user, selecting: false)
    let first = workspace.syncAgentTerminals([("first", "dev")], owner: owner, pruneEnded: true)
    let second = workspace.syncAgentTerminals([("second", "tests")], owner: otherOwner, pruneEnded: true)
    #expect(workspace.syncAgentTerminals([], owner: owner, pruneEnded: false).isEmpty)
    #expect(workspace.allPanes.count == 4)
    let ended = workspace.syncAgentTerminals([], owner: owner, pruneEnded: true)
    #expect(ended.removed == first.updated)
    #expect(workspace.allPanes.contains(user))
    #expect(workspace.allPanes.contains(try #require(second.updated.first)))
    #expect(workspace.selectedCenterTabId == selected)
    #expect(workspace.syncAgentTerminals([], owner: owner, pruneEnded: true).isEmpty)
  }

  @Test("Legacy agent terminals are adopted in place and ownerless unmatched panes survive")
  func adoptLegacy() throws {
    var workspace = workspace()
    let legacy = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Legacy", terminalKey: "legacy", attachOnly: true
    )
    let unmatched = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Other", terminalKey: "other", attachOnly: true
    )
    let tabID = workspace.upsertCenterPane(legacy, selecting: false)
    workspace.upsertCenterPane(unmatched, selecting: false)
    let changes = workspace.syncAgentTerminals([("legacy", "dev")], owner: owner, pruneEnded: true)
    let adopted = try #require(changes.updated.first)
    #expect(adopted.id == legacy.id)
    #expect(adopted.ownerChatSessionId == owner)
    #expect(workspace.tabId(containingPane: adopted.id) == tabID)
    #expect(workspace.allPanes.contains(unmatched))
    #expect(changes.removed.isEmpty)
  }

  @Test("Pruning an agent split preserves its sibling pane and repairs active selection")
  func pruneSplit() {
    var workspace = workspace()
    let chat = workspace.centerTabs[0].root
    let agent = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Agent", terminalKey: "agent",
      attachOnly: true, ownerChatSessionId: owner
    )
    let agentLeaf = UUID()
    let tab = WorkspaceTab(
      root: .split(
        orientation: .horizontal,
        children: [
          SplitChild(fraction: 0.5, node: chat),
          SplitChild(
            fraction: 0.5,
            node: .leaf(
              PaneGroupState(panes: [agent], selectedPaneId: agent.id), id: agentLeaf)),
        ]), activeLeafId: agentLeaf)
    workspace.centerTabs = [tab]
    workspace.selectedCenterTabId = tab.id
    let changes = workspace.syncAgentTerminals([], owner: owner, pruneEnded: true)
    #expect(changes.removed == [agent])
    #expect(workspace.centerTabs.count == 1)
    #expect(workspace.selectedCenterTabId == tab.id)
    #expect(workspace.selectedCenterTab?.activeLeafId == chat.allGroups[0].id)
    #expect(workspace.chatSessionIds == [owner])
  }

  @Test("Matching a user terminal never adopts or prunes it")
  func userTerminalSurvives() {
    var workspace = workspace()
    let user = PaneGroupState.initial(sessionId: owner).panes[0]
    workspace.upsertCenterPane(user, selecting: false)
    #expect(workspace.syncAgentTerminals([(user.terminalKey, "dev")], owner: owner, pruneEnded: true).isEmpty)
    #expect(workspace.syncAgentTerminals([], owner: owner, pruneEnded: true).isEmpty)
    #expect(workspace.allPanes.contains(user))
  }

  @Test("Navigation hides only agent terminals and can reveal the same panes")
  func navigationVisibility() {
    let hide = PaneNavigationVisibility()
    let show = PaneNavigationVisibility(hideAgentTerminals: false)
    for kind in [PaneKind.terminal, .chat, .newTab, .plugin, .document, .browser] {
      for attachOnly in [false, true] {
        let pane = PaneDescriptorState(
          id: UUID(), kind: kind, name: "Pane", terminalKey: "key", attachOnly: attachOnly
        )
        #expect(hide.includes(pane) == !(kind == .terminal && attachOnly))
        #expect(show.includes(pane))
      }
    }
  }

  @MainActor
  @Test("Agent ownership survives server synchronization and stays hidden on receiving devices")
  func ownershipRoundTrip() throws {
    let pane = PaneDescriptorState(
      id: UUID(), kind: .terminal, name: "Agent", terminalKey: "agent",
      attachOnly: true, ownerChatSessionId: owner
    )
    let record = WorkspaceSyncModel.serverPane(
      from: pane, workspaceId: UUID(), createdAt: Date(timeIntervalSince1970: 0)
    )
    let received = try #require(WorkspaceSyncModel.descriptor(from: record))
    #expect(received == pane)
    #expect(!PaneNavigationVisibility().includes(received))
  }
}
