import CodevisorCore
import CodevisorUI
import SwiftUI

extension SessionContainerView {
  /// Document identity belongs to the workspace's machine and canonical
  /// path. Clicking the same document again selects its existing tab/split.
  /// A `preview` open (a click in the navigator) shows the document in the
  /// workspace's preview tab, replacing whatever that tab showed; any other
  /// open of the preview's document pins it.
  @discardableResult
  func openFileDocument(_ target: String, preview: Bool = false) -> Bool {
    guard
      let path = FileDocumentLocation.resolve(
        target, relativeTo: selectedWorkspace.rootDirectory ?? session?.cwd ?? project.folderURL.path)
    else { return false }
    let location = openPreviewable(.document(path: path), preview: preview)
    if let line = FileDocumentLocation.line(target),
      let file = livePane(location.paneId, leafId: location.leafId) as? FilePane
    {
      file.model.editor.goToLine(line)
    }
    return true
  }

  /// One repository-relative file's staged or unstaged changes, as source
  /// control opens them: in the preview tab unless `preview` is false.
  func openFileDiff(_ file: String, staged: Bool, preview: Bool) {
    openPreviewable(.diff(file: file, mode: staged ? .staged : .unstaged), preview: preview)
  }

  /// Opens a document or a diff where `PreviewOpenTarget` says, returning
  /// where it landed.
  @discardableResult
  private func openPreviewable(_ content: PreviewContent, preview: Bool) -> (paneId: UUID, leafId: UUID) {
    var workspace = selectedWorkspace
    if previewDocumentIsDirty { pinPreviewDocument() }
    let previewPaneId = store.previewDocumentPanes[workspace.id]

    switch workspace.openTarget(for: content, preview: preview, previewPaneId: previewPaneId) {
    case let .existing(paneId, leafId):
      if !preview, paneId == previewPaneId { pinPreviewDocument() }
      store.selectDestination(.pane(paneId), in: workspace.id)
      return (paneId, leafId)

    case let .preview(paneId, leafId):
      let group = configuredCenterModel(leafId: leafId)
      if case let .document(path) = content, group.state.panes.first(where: { $0.id == paneId })?.kind == .document,
        let file = livePane(paneId, leafId: leafId) as? FilePane
      {
        // Document to document keeps the editor; its navigation persists
        // and publishes the new path.
        file.model.navigate(to: path)
      } else {
        group.replacePane(id: paneId, with: descriptor(for: content, id: paneId))
      }
      store.selectDestination(.pane(paneId), in: workspace.id)
      return (paneId, leafId)

    case .newTab:
      let pane = descriptor(for: content, id: UUID())
      let state = PaneGroupState(panes: [pane], selectedPaneId: pane.id)
      let tab = WorkspaceTab(root: .leaf(state))
      workspace.centerTabs.append(tab)
      environment.workspaces.save(workspace)
      if preview { store.previewDocumentPanes[workspace.id] = pane.id }
      store.selectDestination(.tab(tab.id), in: workspace.id)
      publishPane(pane, workspaceId: workspace.id)
      focusSelectedCenterPane()
      return (pane.id, tab.activeLeafId)
    }
  }

  /// A pane showing `content`. Diff tabs are titled the way an editor titles
  /// them: the file, then which side of the index it compares.
  private func descriptor(for content: PreviewContent, id: UUID) -> PaneDescriptorState {
    switch content {
    case let .document(path):
      return PaneDescriptorState(
        id: id, kind: .document, name: FileDocumentLocation.name(path), terminalKey: id.uuidString,
        documentPath: path)
    case let .diff(file, mode):
      let side = mode == .staged ? "Index" : "Working Tree"
      return PaneDescriptorState(
        id: id, kind: .review, name: "\((file as NSString).lastPathComponent) (\(side))",
        terminalKey: id.uuidString, review: ReviewPanePreferences(mode: mode, file: file))
    }
  }

  /// Keeps the preview tab: the navigator's next file opens a tab of its own.
  func pinPreviewDocument() {
    store.previewDocumentPanes[selectedWorkspace.id] = nil
  }

  /// Whether the tab holding `paneId` is this workspace's preview tab.
  func isPreviewDocument(_ paneId: UUID?) -> Bool {
    let workspace = selectedWorkspace
    guard let paneId, store.previewDocumentPanes[workspace.id] == paneId else { return false }
    return workspace.reusablePreviewLeaf(paneId) != nil
  }

  /// Editing the preview's document pins it, as in an editor. Reads only a
  /// pane that is already live: an unedited document has nothing to keep.
  var previewDocumentIsDirty: Bool {
    let workspace = selectedWorkspace
    guard let paneId = store.previewDocumentPanes[workspace.id],
      let leafId = workspace.reusablePreviewLeaf(paneId),
      let group = store.centerLeafGroups[SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leafId)],
      let file = group.live[paneId] as? FilePane
    else { return false }
    return file.model.document.isDirty
  }

  private func livePane(_ paneId: UUID, leafId: UUID) -> (any Pane)? {
    let model = configuredCenterModel(leafId: leafId)
    guard let descriptor = model.state.panes.first(where: { $0.id == paneId }) else { return nil }
    return model.pane(for: descriptor)
  }
}
