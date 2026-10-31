import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  func openFileDocument(_ target: String, preview: Bool = false, rendered: Bool = false) -> Bool {
    var workspace = selectedWorkspace
    guard !isSinglePane,
      let path = FileDocumentLocation.resolve(
        target, relativeTo: workspace.rootDirectory ?? session?.cwd ?? project.folderURL.path)
    else { return false }

    for tab in workspace.centerTabs {
      for leaf in tab.root.allGroups {
        if let pane = leaf.state.panes.first(where: {
          $0.kind == .document && $0.documentPath == path
        }) {
          let file = configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
          file?.model.editor.reveal(target, rendered: rendered)
          if !preview, tab.isPreview { keepCenterTab(tab.id) }
          store.selectDestination(.pane(pane.id), in: workspace.id)
          return true
        }
      }
    }

    if preview, let tab = workspace.centerTabs.first(where: \.isPreview) {
      if let file = previewFilePane(in: tab) {
        file.model.navigate(to: path)
        file.model.editor.reveal(target, rendered: rendered)
        store.selectDestination(.tab(tab.id), in: workspace.id)
        focusSelectedCenterPane()
        return true
      }
      keepCenterTab(tab.id)
      workspace = selectedWorkspace
    }

    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: FileDocumentLocation.name(path),
      terminalKey: id.uuidString, documentPath: path
    )
    let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
    let tab = WorkspaceTab(root: .leaf(state), isPreview: preview)
    workspace.centerTabs.append(tab)
    environment.workspaces.save(workspace)
    store.selectDestination(.tab(tab.id), in: workspace.id)
    publishPane(pane, workspaceId: workspace.id)
    let file = tab.root.allGroups.first.flatMap { configuredCenterModel(leafId: $0.id).pane(for: pane) as? FilePane }
    file?.model.editor.reveal(target, rendered: rendered)
    focusSelectedCenterPane()
    return true
  }

  func previewFilePane(in tab: WorkspaceTab) -> FilePane? {
    let groups = tab.root.allGroups
    guard groups.count == 1, let leaf = groups.first, leaf.state.panes.count == 1,
      let pane = leaf.state.panes.first, pane.kind == .document
    else { return nil }
    return configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
  }
}
