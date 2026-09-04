import CodevisorCore
import SwiftUI

extension EnvironmentValues {
  @Entry var openMarkdownDocument: ((String) -> Bool)?
}

extension SessionContainerView {
  /// Document identity belongs to the workspace's machine and canonical
  /// path. Clicking the same document again selects its existing tab/split.
  func openMarkdownDocument(_ target: String) -> Bool {
    var workspace = store.workspace(for: session, project: project)
    guard
      let path = MarkdownDocumentPath.resolve(
        target, relativeTo: workspace.rootDirectory ?? session.cwd ?? project.folderURL.path),
      MarkdownDocumentPath.isMarkdown(path)
    else { return false }

    for tab in workspace.centerTabs {
      for leaf in tab.root.allGroups {
        let model = configuredCenterModel(leafId: leaf.id)
        if let pane = model.state.panes.first(where: {
          $0.kind == .document && $0.documentPath == path
        }) {
          selectCenterTab(tab.id)
          activateLeaf(leaf.id)
          model.select(id: pane.id)
          return true
        }
      }
    }

    if let current = workspace.selectedCenterTab {
      for leaf in current.root.allGroups {
        configuredCenterModel(leafId: leaf.id).selectedPane?.visibilityChanged(false)
      }
    }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: (path as NSString).lastPathComponent,
      terminalKey: id.uuidString, documentPath: path
    )
    let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id, isVisible: true)
    let tab = WorkspaceTab(root: .leaf(state))
    workspace.centerTabs.append(tab)
    workspace.selectedCenterTabId = tab.id
    environment.workspaces.save(workspace)
    workspaceRevision += 1
    liveCenterTree = tab.root
    activateLeaf(tab.activeLeafId)
    publishPane(pane, workspaceId: workspace.id)
    let model = configuredCenterModel(leafId: tab.activeLeafId)
    model.selectedPane?.visibilityChanged(true)
    DispatchQueue.main.async { model.focusSelectedPane() }
    return true
  }
}
