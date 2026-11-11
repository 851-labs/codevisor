import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  func openFileDocument(_ target: String, preview: Bool = false, rendered: Bool = false) -> Bool {
    var workspace = selectedWorkspace
    guard !isTabless,
      let path = FileDocumentLocation.resolve(
        target, relativeTo: workspace.rootDirectory ?? session?.cwd ?? project.folderURL.path)
    else { return false }

    if revealOpenDocument(path, target: target, preview: preview, rendered: rendered, in: workspace) { return true }

    if preview, let tab = workspace.centerTabs.first(where: \.isPreview) {
      if let file = previewFilePane(in: tab) {
        if let leaf = tab.root.allGroups.first { configuredCenterModel(leafId: leaf.id).openInBackground(file.id) }
        file.model.navigate(to: path)
        file.model.editor.reveal(target, rendered: rendered)
        store.selectDestination(.tab(tab.id), in: workspace.id)
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
    let group = tab.root.allGroups.first.map { configuredCenterModel(leafId: $0.id) }
    if preview { group?.openInBackground(pane.id) }
    let file = group?.pane(for: pane) as? FilePane
    file?.model.editor.reveal(target, rendered: rendered)
    if !preview { focusSelectedCenterPane() }
    return true
  }

  private func revealOpenDocument(
    _ path: String, target: String, preview: Bool, rendered: Bool, in workspace: Workspace
  ) -> Bool {
    for tab in workspace.centerTabs {
      for leaf in tab.root.allGroups {
        guard let pane = leaf.state.panes.first(where: { $0.kind == .document && $0.documentPath == path })
        else { continue }
        let group = configuredCenterModel(leafId: leaf.id)
        holdFocus(in: group, on: pane.id, preview: preview)
        (group.pane(for: pane) as? FilePane)?.model.editor.reveal(target, rendered: rendered)
        if !preview, tab.isPreview { keepCenterTab(tab.id) }
        store.selectDestination(.pane(pane.id), in: workspace.id)
        return true
      }
    }
    return false
  }

  private func holdFocus(in group: PaneGroupModel, on paneId: UUID, preview: Bool) {
    if preview {
      group.openInBackground(paneId)
    } else {
      group.backgroundOpen = nil
    }
  }

  func followFileRename(from source: String, to destination: String) {
    for tab in selectedWorkspace.centerTabs {
      for leaf in tab.root.allGroups {
        let model = configuredCenterModel(leafId: leaf.id)
        for pane in leaf.state.panes where Self.isRenamed(pane, from: source, to: destination) {
          guard let file = model.pane(for: pane) as? FilePane else { continue }
          Task { await file.model.followRename(from: source, to: destination) }
        }
      }
    }
  }

  private static func isRenamed(_ pane: PaneDescriptorState, from source: String, to destination: String) -> Bool {
    guard pane.kind == .document, let path = pane.documentPath else { return false }
    return FilePaneModel.renamedPath(path, from: source, to: destination) != nil
  }

  func previewFilePane(in tab: WorkspaceTab) -> FilePane? {
    let groups = tab.root.allGroups
    guard groups.count == 1, let leaf = groups.first, leaf.state.panes.count == 1,
      let pane = leaf.state.panes.first, pane.kind == .document
    else { return nil }
    return configuredCenterModel(leafId: leaf.id).pane(for: pane) as? FilePane
  }
}
