import SwiftUI
import CodevisorCore

extension SessionContainerView {
  var floatingLayout: WorkspaceFloatingLayout {
    let workspace = selectedWorkspace
    return WorkspaceFloatingLayout(workspace: workspace, flagged: FloatingPanes.shared.leafIds(in: workspace.id))
  }

  func isFloating(_ leafId: UUID) -> Bool {
    FloatingPanes.shared.leafIds(in: selectedWorkspace.id).contains(leafId)
  }

  func paneFocus(forLeaf leafId: UUID) -> TerminalFocusController {
    guard isFloating(leafId) else { return sessionFocus }
    return FloatingPaneWindows.shared.focus(for: floatingKey(leafId)) ?? sessionFocus
  }

  func isFloatingPaneFocused(_ leafId: UUID) -> Bool {
    FloatingPaneWindows.shared.isKey(floatingKey(leafId))
  }

  func floatLeaf(_ leafId: UUID) {
    let workspace = selectedWorkspace
    guard !isSinglePane, let tab = workspace.selectedCenterTab,
      floatingLayout.canFloat(leafId, in: tab.root)
    else { return }

    FloatingPanes.shared.float(floatingKey(leafId))
    if leafId == activeLeafId {
      activateLeaf(floatingLayout.visibleTree(tab.root).allGroups.first?.id)
    }
    presentFloatingPane(leafId, activating: true)
  }

  func returnFloatingLeaf(_ leafId: UUID) {
    FloatingPanes.shared.dock(floatingKey(leafId))
    FloatingPaneWindows.shared.dismiss(floatingKey(leafId))
    configuredCenterModel(leafId: leafId).selectedPane?.visibilityChanged(isVisible)
    activateLeaf(leafId)
    focusSelectedCenterPane()
  }

  func restoringFloatingLeaves(_ visible: SplitNode) -> SplitNode {
    floatingLayout.restoring(visible, in: liveCenterTree ?? selectedWorkspace.centerTree)
  }

  func syncFloatingPanes() {
    let workspace = selectedWorkspace
    let layout = floatingLayout
    FloatingPanes.shared.dock(Set(layout.stale.map(floatingKey)))
    FloatingPaneWindows.shared.dismiss(in: workspace.id, keeping: layout.floating, by: focusSourceId)
    for leafId in layout.floating where !FloatingPaneWindows.shared.isPresented(floatingKey(leafId), by: focusSourceId)
    {
      presentFloatingPane(leafId, activating: false)
    }
  }

  func dismissFloatingPanes() {
    FloatingPaneWindows.shared.dismiss(in: selectedWorkspace.id, keeping: [], by: focusSourceId)
  }

  func raiseIfFloating(_ leafId: UUID?) {
    guard let leafId, isFloating(leafId) else { return }

    FloatingPaneWindows.shared.raise(floatingKey(leafId))
  }

  private func floatingKey(_ leafId: UUID) -> FloatingPaneKey {
    FloatingPaneKey(workspaceId: selectedWorkspace.id, leafId: leafId)
  }

  private func presentFloatingPane(_ leafId: UUID, activating: Bool) {
    let model = configuredCenterModel(leafId: leafId)
    let request = FloatingPaneRequest(
      key: floatingKey(leafId),
      owner: focusSourceId,
      activating: activating,
      attention: floatingAttention(model),
      onClose: { closeLeaf(leafId) }
    )
    FloatingPaneWindows.shared.present(request) { focus in
      FloatingPaneView(
        group: model,
        focus: focus,
        title: paneTitle,
        onCommand: { floatingPaneCommand($0, leafId: leafId) },
        onReturn: { returnFloatingLeaf(leafId) }
      )
      .modifier(workspacePaneActions)
      .appWindowRoot(environment)
    }
    model.selectedPane?.visibilityChanged(true)
    if activating { model.requestSelectedPaneFocus() }
  }

  private func floatingAttention(_ model: PaneGroupModel) -> FloatingPaneAttention {
    let serverId = selectedWorkspace.serverId
    return FloatingPaneAttention(coordinator: environment.attentionCoordinator) { [weak model] in
      model?.state.selectedPane?.chatSessionId.map { SessionAttentionFocus(serverId: serverId, sessionId: $0) }
    }
  }

  func floatingPaneCommand(_ command: PaneGroupCommand, leafId: UUID) -> Bool {
    if case .closeTab = command { closeLeaf(leafId) }
    return true
  }
}
