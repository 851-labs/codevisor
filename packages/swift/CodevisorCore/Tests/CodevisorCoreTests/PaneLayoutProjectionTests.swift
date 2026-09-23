import Foundation
import Testing
@testable import CodevisorCore

struct PaneLayoutProjectionTests {
  private func pane(_ name: String, kind: PaneKind = .terminal) -> PaneDescriptorState {
    let id = UUID()
    return PaneDescriptorState(id: id, kind: kind, name: name, terminalKey: id.uuidString)
  }

  private func group(_ pane: PaneDescriptorState) -> PaneGroupState {
    PaneGroupState(panes: [pane], selectedPaneId: pane.id)
  }

  /// A macOS-style workspace: one split tab (chat | terminal) and one plain tab.
  private func fixture() -> (
    Workspace, chat: PaneDescriptorState, terminal: PaneDescriptorState, browser: PaneDescriptorState
  ) {
    let chat = PaneDescriptorState(
      id: UUID(), kind: .chat, name: "Chat", terminalKey: "chat", chatSessionId: UUID()
    )
    let terminal = pane("Terminal 1")
    let browser = pane("Docs", kind: .browser)
    let chatLeaf = UUID()
    let terminalLeaf = UUID()
    let splitTab = WorkspaceTab(
      root: .split(
        orientation: .horizontal,
        children: [
          SplitChild(fraction: 0.6, node: .group(id: chatLeaf, state: group(chat))),
          SplitChild(fraction: 0.4, node: .group(id: terminalLeaf, state: group(terminal))),
        ]
      ),
      activeLeafId: chatLeaf
    )
    let plainTab = WorkspaceTab(root: .leaf(group(browser)))
    let workspace = Workspace(
      name: "Project", rootDirectory: "/fixture", serverId: "machine", projectId: UUID(),
      centerTabs: [splitTab, plainTab], createdAt: Date(timeIntervalSince1970: 0)
    )
    return (workspace, chat, terminal, browser)
  }

  @Test("Flattening lists every pane in tree order with the active leaf selected")
  func flatten() {
    let (workspace, chat, terminal, browser) = fixture()
    let flat = PaneLayoutProjection.flatten(workspace)
    #expect(flat.panes.map(\.id) == [chat.id, terminal.id, browser.id])
    #expect(flat.selectedPaneId == chat.id)
  }

  @Test("Applying an unchanged flat state keeps the split tree intact")
  func roundTripKeepsSplit() {
    var (workspace, _, _, _) = fixture()
    let before = workspace.centerTabs
    PaneLayoutProjection.apply(PaneLayoutProjection.flatten(workspace), to: &workspace)
    #expect(workspace.centerTabs == before)
  }

  @Test("Selecting a pane inside a split activates its tab and leaf, not a new tab")
  func selectionMapsToLeaf() {
    var (workspace, _, terminal, _) = fixture()
    var flat = PaneLayoutProjection.flatten(workspace)
    flat.selectPane(id: terminal.id)
    PaneLayoutProjection.apply(flat, to: &workspace)
    #expect(workspace.centerTabs.count == 2)
    let tab = workspace.selectedCenterTab
    #expect(tab?.root.allGroups.count == 2)
    #expect(tab.flatMap { $0.root.group(id: $0.activeLeafId)?.selectedPaneId } == terminal.id)
  }

  @Test("A conversion keeps the pane in its leaf because the id is stable")
  func conversionStaysInPlace() {
    var (workspace, _, terminal, _) = fixture()
    var flat = PaneLayoutProjection.flatten(workspace)
    let replaced = flat.replacePaneWithNewTab(id: terminal.id)
    #expect(replaced?.id == terminal.id)
    PaneLayoutProjection.apply(flat, to: &workspace)
    let splitTab = workspace.centerTabs[0]
    #expect(splitTab.root.allGroups.count == 2)
    #expect(splitTab.root.allGroups[1].state.panes.first?.kind == .newTab)
  }

  @Test("Closing a pane inside a split collapses the split to the survivor")
  func closingCollapsesSplit() {
    var (workspace, chat, terminal, browser) = fixture()
    var flat = PaneLayoutProjection.flatten(workspace)
    #expect(flat.closePane(id: terminal.id) != nil)
    PaneLayoutProjection.apply(flat, to: &workspace)
    #expect(workspace.centerTabs.count == 2)
    #expect(workspace.centerTabs[0].root.allGroups.map { $0.state.panes.map(\.id) } == [[chat.id]])
    #expect(workspace.centerTabs[1].root.allGroups.map { $0.state.panes.map(\.id) } == [[browser.id]])
  }

  @Test("A new pane appends as its own tab and can be selected")
  func newPaneAppendsTab() {
    var (workspace, _, _, _) = fixture()
    var flat = PaneLayoutProjection.flatten(workspace)
    let added = flat.addNewTabPane()
    PaneLayoutProjection.apply(flat, to: &workspace)
    #expect(workspace.centerTabs.count == 3)
    #expect(workspace.centerTabs[2].root.allGroups.first?.state.panes.map(\.id) == [added.id])
    #expect(workspace.selectedCenterTabId == workspace.centerTabs[2].id)
  }

  @Test("A draft adopting a session replaces the workspace's seeded chat pane, keeping the draft's id")
  func draftReplacesSeededChatPane() {
    let sessionId = UUID()
    // What `ensureWorkspace` mints for a first send: a chat pane with its own id.
    var workspace = Workspace(
      name: "Project", rootDirectory: "/fixture", serverId: "machine", projectId: UUID(),
      centerTabs: [WorkspaceTab(root: .leaf(.centerInitial(sessionId: sessionId)))],
      createdAt: Date(timeIntervalSince1970: 0)
    )
    let seeded = workspace.centerTabs[0].root.allGroups[0].state.panes[0]
    // The draft pane, whose id the mounted transcript is keyed on.
    let draftPaneId = UUID()
    var draft = PaneGroupState.centerInitial(sessionId: UUID(), paneId: draftPaneId)
    draft.panes[0].chatSessionId = sessionId
    PaneLayoutProjection.apply(draft, to: &workspace)
    let panes = workspace.centerTabs.flatMap { $0.root.allGroups.flatMap(\.state.panes) }
    #expect(panes.map(\.id) == [draftPaneId])
    #expect(panes.first?.id != seeded.id)
    #expect(PaneLayoutProjection.flatten(workspace).selectedPaneId == draftPaneId)
  }

  @Test("Removing every pane leaves the local placeholder tab")
  func emptyBecomesPlaceholder() {
    var (workspace, _, _, _) = fixture()
    PaneLayoutProjection.apply(PaneGroupState(), to: &workspace)
    #expect(workspace.centerTabs.count == 1)
    #expect(workspace.centerTabs[0].isPlaceholder)
    #expect(workspace.selectedCenterTabId == workspace.centerTabs[0].id)
  }
}
