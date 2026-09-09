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
        if let pane = leaf.state.panes.first(where: {
          $0.kind == .document && $0.documentPath == path
        }) {
          store.selectDestination(.pane(pane.id), in: workspace.id)
          return true
        }
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
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    focusSelectedCenterPane()
    return true
  }
}
