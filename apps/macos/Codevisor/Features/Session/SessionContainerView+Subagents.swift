import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  func openSubagent(
    parentSessionId: UUID, toolCallId: String, title: String, placement: OpenSubagentAction.Placement
  ) {
    guard !isSinglePane else { return }
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
    environment.workspaces.save(workspace)
    store.reconcileMountedPaneGroups(in: workspace)
    store.selectDestination(.tab(inserted.tabId), in: workspace.id)
    focusSelectedCenterPane()
  }

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
