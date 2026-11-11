import SwiftUI
import CodevisorCore

extension SessionContainerView {
  var floatingLayout: WorkspaceFloatingLayout {
    let workspace = selectedWorkspace
    return WorkspaceFloatingLayout(workspace: workspace, flagged: FloatingPanes.shared.leafIds(in: workspace.id))
  }

  func isFloating(_ leafId: UUID) -> Bool {
    floatingLayout.floating.contains(leafId)
  }

  @ViewBuilder
  func floatingPaneOverlay(chatLeaf: (id: UUID, state: PaneGroupState)?) -> some View {
    if chatLeaf == nil {
      FloatingPaneOverlay(
        panes: floatingPanesInSelectedTab,
        group: { configuredCenterModel(leafId: $0) },
        title: paneTitle,
        actions: floatingPaneActions
      )
    }
  }

  func floatLeaf(_ leafId: UUID) {
    guard !isSinglePane, let tab = selectedWorkspace.selectedCenterTab,
      floatingLayout.canFloat(leafId, in: tab.root)
    else { return }

    let model = configuredCenterModel(leafId: leafId)
    floatingFocusHandoff.begin(in: sessionFocus.hostWindow) { responder in
      PaneActivationObserver.ClickObserverView.isInFloatingPane(responder)
    }
    FloatingPanes.shared.float(floatingKey(leafId))
    activateLeaf(leafId)
    sessionFocus.centerGroup = model
    model.selectedPane?.focus()
    focusSelectedCenterPane()
  }

  func returnFloatingLeaf(_ leafId: UUID) {
    FloatingPanes.shared.dock(floatingKey(leafId))
    activateLeaf(leafId)
    focusSelectedCenterPane()
  }

  func restoringFloatingLeaves(_ visible: SplitNode) -> SplitNode {
    floatingLayout.restoring(visible, in: liveCenterTree ?? selectedWorkspace.centerTree)
  }

  func dockStaleFloatingPanes() {
    FloatingPanes.shared.dock(Set(floatingLayout.stale.map(floatingKey)))
  }

  func bringFloatingPaneToFront(_ leafId: UUID?) {
    guard let leafId, isFloating(leafId) else { return }

    FloatingPanes.shared.bringToFront(floatingKey(leafId))
  }

  private var floatingPanesInSelectedTab: [FloatingPane] {
    let workspace = selectedWorkspace
    let floating = floatingLayout.floating
    guard let tab = workspace.selectedCenterTab else { return [] }

    return FloatingPanes.shared.panes(in: workspace.id).filter {
      floating.contains($0.leafId) && tab.root.group(id: $0.leafId) != nil
    }
  }

  private func floatingPaneActions(_ leafId: UUID) -> FloatingPaneActions {
    FloatingPaneActions(
      move: { FloatingPanes.shared.move(floatingKey(leafId), to: $0) },
      activate: { configuredCenterModel(leafId: leafId).onActivated?() },
      returnToWorkspace: { returnFloatingLeaf(leafId) },
      close: { closeLeaf(leafId) }
    )
  }

  private func floatingKey(_ leafId: UUID) -> FloatingPaneKey {
    FloatingPaneKey(workspaceId: selectedWorkspace.id, leafId: leafId)
  }
}
