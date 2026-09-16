import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  /// Document identity belongs to the workspace's machine and canonical
  /// path. Clicking the same document again selects its existing tab/split.
  func openFileDocument(_ target: String) -> Bool {
    var workspace = selectedWorkspace
    guard
      let path = FileDocumentLocation.resolve(
        target, relativeTo: workspace.rootDirectory ?? session?.cwd ?? project.folderURL.path)
    else { return false }

    for tab in workspace.centerTabs {
      for leaf in tab.root.allGroups {
        if let pane = leaf.state.panes.first(where: {
          $0.kind == .document && $0.documentPath == path
        }) {
          if let line = FileDocumentLocation.line(target),
            let file = configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
          {
            file.model.editor.goToLine(line)
          }
          store.selectDestination(.pane(pane.id), in: workspace.id)
          return true
        }
      }
    }

    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: FileDocumentLocation.name(path),
      terminalKey: id.uuidString, documentPath: path
    )
    let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
    let tab = WorkspaceTab(root: .leaf(state))
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    if let line = FileDocumentLocation.line(target), let leaf = tab.root.allGroups.first,
      let file = configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
    {
      file.model.editor.goToLine(line)
    }
    focusSelectedCenterPane()
    return true
  }
}
