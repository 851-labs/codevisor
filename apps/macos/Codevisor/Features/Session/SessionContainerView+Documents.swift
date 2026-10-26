import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  func openFileDocument(_ target: String, preview: Bool = false) -> Bool {
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
          if let line = FileDocumentLocation.line(target),
            let file = configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
          {
            file.model.editor.goToLine(line)
          }
          if !preview, tab.isPreview { keepCenterTab(tab.id) }
          store.selectDestination(.pane(pane.id), in: workspace.id)
          return true
        }
      }
    }

    if preview, let tab = workspace.centerTabs.first(where: \.isPreview) {
      if let file = previewFilePane(in: tab) {
        file.model.navigate(to: path)
        if let line = FileDocumentLocation.line(target) { file.model.editor.goToLine(line) }
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
    if let line = FileDocumentLocation.line(target), let leaf = tab.root.allGroups.first,
      let file = configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
    {
      file.model.editor.goToLine(line)
    }
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
