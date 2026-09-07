import CodevisorCore
import CodevisorUI
import SwiftUI

extension SidebarView {
  var workspaceOrder: WorkspaceSidebarOrder {
    WorkspaceSidebarOrder(
      manualWorkspaceOrderRaw.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
    )
  }

  func manuallyOrderedWorkspaces(_ items: [SidebarWorkspaceListItem]) -> [SidebarWorkspaceListItem] {
    let byID = Dictionary(items.map { ($0.workspace.id, $0) }, uniquingKeysWith: { first, _ in first })
    return workspaceOrder.applying(to: items.map(\.workspace.id)).compactMap { byID[$0] }
  }

  func rememberWorkspaceOrder(_ visibleIDs: [UUID]) {
    let saved = workspaceOrder
    let updated = saved.including(visibleIDs)
    guard updated.ids != saved.ids else { return }
    saveWorkspaceOrder(updated.ids)
  }

  func moveWorkspace(_ sourceID: UUID, to destinationID: UUID) {
    let updated = workspaceOrder.moving(sourceID, to: destinationID, visibleIDs: workspaceItems.map(\.workspace.id))
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) {
      saveWorkspaceOrder(updated.ids)
    }
  }

  private func saveWorkspaceOrder(_ ids: [UUID]) {
    manualWorkspaceOrderRaw = ids.map(\.uuidString).joined(separator: "\n")
  }

}
