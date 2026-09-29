import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  /// Opens a subagent's thread as a read-only pane beside its parent chat.
  /// The default is a split, so the parent stays in view; that split is the
  /// chat's single agent viewer, so opening another of the chat's agents
  /// replaces it rather than splitting again. Opening a subagent that's
  /// already showing selects it.
  func openSubagent(
    parentSessionId: UUID, toolCallId: String, title: String, placement: OpenSubagentAction.Placement
  ) {
    var workspace = selectedWorkspace
    if let existing = workspace.allPanes.first(where: {
      $0.kind == .subagent && $0.ownerChatSessionId == parentSessionId && $0.subagentToolCallId == toolCallId
    }) {
      store.selectDestination(.pane(existing.id), in: workspace.id)
      focusSelectedCenterPane()
      return
    }
    guard let parentPane = workspace.pane(containingChat: parentSessionId) else { return }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .subagent, name: title, terminalKey: id.uuidString,
      ownerChatSessionId: parentSessionId, subagentToolCallId: toolCallId
    )

    let inserted: (tabId: UUID, leafId: UUID)?
    switch placement {
    case .newTab:
      inserted = workspace.insertPane(pane, besidePane: parentPane.id, destination: .foregroundTab)
    case .automatic, .split:
      if let viewerPaneId = agentViewer(for: parentSessionId, besidePane: parentPane.id, in: workspace) {
        inserted = workspace.replacePane(id: viewerPaneId, with: pane)
      } else {
        inserted = workspace.insertPane(pane, besidePane: parentPane.id, destination: .split(.trailing))
      }
    }
    guard let inserted else { return }
    // Device-local: this Mac's layout only; never published.
    environment.workspaces.save(workspace)
    // A leaf already on screen holds its own model; new leaves build theirs
    // from the saved state.
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
  }

  /// The agent pane in a split beside the chat, if one is showing.
  private func agentViewer(
    for parentSessionId: UUID, besidePane parentPaneId: UUID, in workspace: Workspace
  ) -> UUID? {
    guard let tab = workspace.centerTabs.first(where: { $0.root.groupId(containingPane: parentPaneId) != nil })
    else { return nil }
    return tab.root.allGroups.lazy.flatMap(\.state.panes).first {
      $0.kind == .subagent && $0.ownerChatSessionId == parentSessionId
    }?.id
  }

}
