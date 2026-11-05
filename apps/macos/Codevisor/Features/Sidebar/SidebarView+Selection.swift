import SwiftUI
import CodevisorCore
import CodevisorUI

extension SidebarView {
  var workspaceSections: [[SidebarWorkspaceListItem]] {
    SidebarRows.activeWorkspaceSections(sidebarRows).map { $0.compactMap(listItem(for:)) }
  }

  func moveSelection(awayFrom workspace: Workspace) {
    let sections = workspaceSections
    let next = SidebarArchiveSelection.after(
      archiving: workspace.id, selected: routesSelectedSession(workspace) ? workspace.id : nil,
      sections: sections.map { $0.map(\.workspace.id) })
    switch next {
    case .unchanged:
      return
    case .clear:
      commitNow(nil)
    case let .select(id):
      guard let item = sections.joined().first(where: { $0.workspace.id == id }) else { return }
      revealRequest.rowID = id
      commitNow(item, awayFrom: workspace)
    }
  }

  private func commitNow(_ target: SidebarSelection?) {
    navigation.cancelPending()
    navigation.committed.wrappedValue = target
  }

  private func commitNow(_ item: SidebarWorkspaceListItem, awayFrom workspace: Workspace) {
    let navigator = navigator
    navigation.cancelPending()
    navigator.activate(item)
    if navigator.routesSelectedSession(workspace) { navigation.committed.wrappedValue = nil }
  }
}
