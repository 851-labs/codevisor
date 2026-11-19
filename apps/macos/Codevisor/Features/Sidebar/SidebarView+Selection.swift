import SwiftUI
import CodevisorCore
import CodevisorUI

extension SidebarView {
  var workspaceSections: [[SidebarWorkspaceListItem]] {
    SidebarRows.activeWorkspaceSections(sidebarRows).map { $0.compactMap(listItem(for:)) }
  }

  var workspaceSectionIDs: [[UUID]] {
    workspaceSections.map { $0.map(\.workspace.id) }
  }

  func moveSelection(awayFrom workspace: Workspace) {
    moveSelection(awayFrom: workspace, isShown: routesSelectedSession(workspace), sections: workspaceSectionIDs)
  }

  func followArchivedSelection(from previous: [[UUID]], to current: [[UUID]]) {
    let left = Set(previous.joined()).subtracting(current.joined())
    let shown = left.lazy.compactMap { environment.navigationStore.workspaceEntries.entry($0).workspace }
      .first { $0.isArchived && showsArchived($0) }
    guard let shown else { return }

    moveSelection(awayFrom: shown, isShown: true, sections: previous)
  }

  private func showsArchived(_ workspace: Workspace) -> Bool {
    if case let .archivedWorkspace(serverId, id) = selection {
      return serverId == workspace.serverId && id == workspace.id
    }
    return routesSelectedSession(workspace)
  }

  private func moveSelection(awayFrom workspace: Workspace, isShown: Bool, sections: [[UUID]]) {
    let next = SidebarArchiveSelection.after(
      archiving: workspace.id, selected: isShown ? workspace.id : nil, sections: sections)
    switch next {
    case .unchanged:
      return
    case .clear:
      selection = nil
    case let .select(id):
      guard let item = workspaceSections.joined().first(where: { $0.workspace.id == id }) else { return }
      revealRequest.rowID = id
      activateWorkspace(item)
      if routesSelectedSession(workspace) { selection = nil }
    }
  }
}
