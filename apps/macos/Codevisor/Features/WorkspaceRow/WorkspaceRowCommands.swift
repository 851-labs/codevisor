import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
struct WorkspaceRowCommands {
  let environment: AppEnvironment
  @Binding var pinnedIDs: [String]
  let rename: @MainActor (Workspace) -> Void
  let newSection: @MainActor (Workspace) -> Void
  var willArchive: @MainActor (Workspace) -> Void = { _ in }

  func actions(
    for workspace: Workspace, isPinned: Bool, sectionPlacement: WorkspaceSectionPlacement?
  ) -> WorkspaceRowActions {
    WorkspaceRowActions(
      isPinned: isPinned,
      togglePin: { togglePin(workspace) },
      rename: { rename(workspace) },
      archive: { archive(workspace) },
      sectionMenu: sectionPlacement.map { sectionMenu(for: workspace, in: $0) }
    )
  }

  func isPinned(_ workspace: Workspace) -> Bool {
    pinnedIDs.contains(workspace.id.uuidString)
  }

  func togglePin(_ workspace: Workspace) {
    let id = workspace.id.uuidString
    if pinnedIDs.contains(id) {
      pinnedIDs.removeAll { $0 == id }
    } else {
      pinnedIDs.append(id)
    }
  }

  func archive(_ workspace: Workspace) {
    willArchive(workspace)
    environment.archiveWorkspace(workspace)
    pinnedIDs.removeAll { $0 == workspace.id.uuidString }
    environment.workspaceSections.forget(workspace.id)
  }

  private func sectionMenu(for workspace: Workspace, in placement: WorkspaceSectionPlacement) -> MoveToSectionMenu {
    let sections = environment.workspaceSections
    return MoveToSectionMenu(
      currentSectionID: placement.sectionID, sections: sections.sections,
      move: { sections.move(workspace.id, to: $0) }, newSection: { newSection(workspace) })
  }
}
