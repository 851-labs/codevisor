import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

extension SidebarView {
  /// Archived projects and chats, kept in one collapsed disclosure at the
  /// bottom of the sidebar rather than a separate screen — restoring stays a
  /// two-click operation in the place the user already is.
  ///
  /// Archived chats of an ARCHIVED project are intentionally omitted: they
  /// appear nested under that project once it is restored. Listing them at
  /// this level too would show the same chat twice.
  @ViewBuilder
  var archivedSection: some View {
    let projects = list.archivedProjects
    // Chats archived inside an ARCHIVED project are omitted: they come
    // back with that project, and listing them here as well would show
    // the same chat in two places.
    let archivedProjectIDs = Set(projects.map(\.id))
    let chats = list.archivedSessions.compactMap { session -> SidebarSessionListItem? in
      guard !archivedProjectIDs.contains(session.projectId),
        let project = list.projects.first(where: {
          $0.serverId == session.serverId && $0.id == session.projectId
        })
      else { return nil }
      return SidebarSessionListItem(session: session, project: project)
    }
    if !projects.isEmpty || !chats.isEmpty {
      archivedHeader
      if archivedExpanded {
        ForEach(projects, id: \.sidebarFleetItemID) { project in
          archivedProjectRow(project)
            .transition(Motion.unfold(reduceMotion: reduceMotion))
        }
        // Paged: a long archive would otherwise make every sidebar
        // reflow lay out hundreds of rows it never shows.
        ForEach(chats.prefix(archivedVisibleCount)) { item in
          archivedSessionRow(item.session, project: item.project)
            .transition(Motion.unfold(reduceMotion: reduceMotion))
        }
        if chats.count > archivedVisibleCount {
          showMoreArchivedRow(remaining: chats.count - archivedVisibleCount)
            .transition(Motion.unfold(reduceMotion: reduceMotion))
        }
      }
    }
  }

  private func showMoreArchivedRow(remaining: Int) -> some View {
    SidebarShowMoreArchivedRow(
      remaining: remaining,
      pageSize: archivedPageSize,
      titleFont: itemTitleFont,
      archivedVisibleCount: $archivedVisibleCount,
      isLoadingMoreArchived: $isLoadingMoreArchived
    )
  }

  private var archivedHeader: some View {
    SidebarArchivedHeader(archivedExpanded: $archivedExpanded)
  }

  /// Archived rows deliberately reuse the live row builders rather than
  /// defining their own look: an archived chat should be visually identical
  /// to an active one in whichever organization is selected, so the archive
  /// reads as the same list rather than a separate widget. `isArchivedEntry`
  /// only swaps the row's behavior (click asks to restore, and the archive
  /// affordances are dropped), never its styling.
  private func archivedProjectRow(_ project: Project) -> some View {
    projectRow(project, isArchivedEntry: true)
  }

  @ViewBuilder
  private func archivedSessionRow(_ session: ChatSession, project: Project) -> some View {
    // Every organization deliberately shares the exact same agent row;
    // only the live hierarchy around it changes.
    chronologicalSessionRow(session, project: project, isArchivedEntry: true)
  }

  /// Restores a chat and revives its workspace, mirroring the archive
  /// policy in reverse (`archiveSessionAndWorkspaceIfEmpty`).
  private func restoreChat(_ session: ChatSession) {
    list.unarchiveSession(session)
    if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
      let workspace = environment.workspaces.workspace(id: workspaceId),
      workspace.isArchived
    {
      environment.unarchiveWorkspace(workspace)
    }
    workspaceRevision += 1
  }

  /// Applies a confirmed restore and opens the chat, which is what the user
  /// was reaching into the archive for.
  func performRestore(_ request: ArchivedRestoreRequest) {
    switch request.target {
    case let .project(project):
      list.unarchive(project)
    case let .session(session):
      restoreChat(session)
      activateSession(session)
    }
  }
}
