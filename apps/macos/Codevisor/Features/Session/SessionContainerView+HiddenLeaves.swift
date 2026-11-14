import CodevisorCore
import SwiftUI

extension SessionContainerView {
  var leavesCoveredByPage: Set<UUID> {
    let covered = environment.leavesCoveredByBotPage(in: selectedWorkspace)
    let leaves = Set(selectedWorkspace.centerTree.allGroups.map(\.id))
    return leaves.isSubset(of: covered.union(floatingLayout.floating)) ? [] : covered
  }

  var hiddenLeaves: Set<UUID> {
    floatingLayout.floating.union(leavesCoveredByPage)
  }

  func visibleTree(_ tree: SplitNode) -> SplitNode {
    SplitTreeVisibility.visible(tree, hiding: hiddenLeaves) ?? tree
  }

  func restoringHiddenLeaves(_ visible: SplitNode) -> SplitNode {
    SplitTreeVisibility.restoring(hiddenLeaves, in: liveCenterTree ?? selectedWorkspace.centerTree, from: visible)
  }

  func showPage(covering covered: Set<UUID>, uncovering uncovered: Set<UUID>) {
    guard isVisible else { return }

    setPanesVisible(false, in: covered)
    setPanesVisible(true, in: uncovered)
    guard let active = activeLeafId, covered.contains(active) else { return }
    activateLeaf(selectedWorkspace.centerTree.allGroups.map(\.id).first { !covered.contains($0) })
  }

  private func setPanesVisible(_ visible: Bool, in leaves: Set<UUID>) {
    let workspace = selectedWorkspace
    for leafId in leaves {
      let key = SessionStore.CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
      store.centerLeafGroups[key]?.selectedPane?.visibilityChanged(visible)
    }
  }
}
