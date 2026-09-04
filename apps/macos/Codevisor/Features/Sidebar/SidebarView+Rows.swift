import SwiftUI
import UniformTypeIdentifiers
import CodevisorCore
import CodevisorTheming
import os
import CodevisorUI

extension SidebarView {
  // MARK: - Project rows

  @ViewBuilder
  func projectFolder(_ group: ProjectGroup) -> some View {
    reorderableProjectRow(group)

    // Keep the persisted disclosure state intact while making the list
    // compact enough to reorder. Ending the drag restores every folder
    // exactly as the user left it.
    if isProjectVisuallyExpanded(group.id) {
      let sessions = orderedSessions(in: group)
      ForEach(sessions, id: \.sidebarFleetItemID) { session in
        // Each chat keeps ITS machine's record: the subtitle names
        // that machine, and the row's actions target that server.
        reorderableChronologicalSessionRow(
          session,
          project: group.member(serverId: session.serverId, projectId: session.projectId)
            ?? group.primary,
          isNested: true
        )
        .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
      }
      if sessions.isEmpty {
        Text("No chats yet")
          .font(.subheadline)
          .foregroundStyle(.tertiary)
          .padding(.leading, 16)
          .padding(.vertical, 3)
          .transition(.opacity)
      }
    }
  }

  /// Drag identity is the group's primary record: a stable UUID for the
  /// drop delegates, resolved back to the whole group when reordering.
  @ViewBuilder
  private func reorderableProjectRow(_ group: ProjectGroup) -> some View {
    if order == .none {
      projectRow(group)
        .onDrag(
          {
            draggingProjectID = group.primary.id
            return NSItemProvider(object: group.primary.id.uuidString as NSString)
          },
          preview: {
            projectRow(group, isDragPreview: true)
              .frame(width: 260)
          }
        )
        .opacity(draggingProjectID == group.primary.id ? 0 : 1)
        .onDrop(
          of: [.text],
          delegate: ProjectDropDelegate(
            projectID: group.primary.id,
            draggingProjectID: $draggingProjectID,
            moveProject: moveProject
          )
        )
    } else {
      projectRow(group)
    }
  }

  func projectRow(
    _ group: ProjectGroup,
    isDragPreview: Bool = false,
    isArchivedEntry: Bool = false
  ) -> some View {
    SidebarProjectRow(
      group: group,
      isDragPreview: isDragPreview,
      isArchivedEntry: isArchivedEntry,
      isReordering: isReordering,
      isVisuallyExpanded: isProjectVisuallyExpanded(group.id),
      titleFont: itemTitleFont,
      machineNames: machineNames(for: group),
      onDisclosureToggle: { toggle(group.id) },
      onRestoreRequest: {
        restoreRequest = ArchivedRestoreRequest(target: .project(group.primary))
      },
      // A new chat in a linked project starts on the machine that used
      // it most recently.
      onNewChat: { selection = .newChat(NewChatTarget(list.mostRecentlyUsedMember(of: group))) },
      // Archiving the project archives it everywhere it is checked out.
      onArchive: { group.members.forEach(list.archive) }
    )
  }

  /// The machines holding this project, for the folder's subtitle. Nil in
  /// single-machine fleets, where the machine goes without saying.
  private func machineNames(for group: ProjectGroup) -> String? {
    var names: [String] = []
    for serverId in group.serverIds {
      guard let name = environment.machines.fleetMachineName(for: serverId),
        !names.contains(name)
      else { continue }
      names.append(name)
    }
    return names.isEmpty ? nil : names.joined(separator: ", ")
  }

  /// The expansion key of the "No project" folder, alongside group ids.
  static let noProjectFolderID = "no-project"

  @ViewBuilder
  var noProjectFolder: some View {
    SidebarNoProjectRow(
      isReordering: isReordering,
      isVisuallyExpanded: isProjectVisuallyExpanded(Self.noProjectFolderID),
      titleFont: itemTitleFont,
      onDisclosureToggle: { toggle(Self.noProjectFolderID) }
    )
    if isProjectVisuallyExpanded(Self.noProjectFolderID) {
      ForEach(looseProjectSessions) { item in
        reorderableChronologicalSessionRow(item.session, project: item.project, isNested: true)
          .transition(.opacity.combined(with: .scale(scale: 0.98, anchor: .top)))
      }
    }
  }

  private func disclosureRow(
    id: String,
    title: String,
    systemImage: String?,
    isOpen: Bool,
    toggle: @escaping () -> Void
  ) -> some View {
    HStack(spacing: 6) {
      Image(systemName: "chevron.right")
        .font(.caption2.weight(.semibold))
        .foregroundStyle(.secondary)
        .rotationEffect(.degrees(isOpen ? 90 : 0))
      if let systemImage {
        Image(systemName: systemImage).frame(width: 18).foregroundStyle(.secondary)
      }
      Text(title).fontWeight(.medium).lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 5)
    .frame(maxWidth: .infinity, alignment: .leading)
    .contentShape(Rectangle())
    .sidebarRowHover(isEnabled: !isReordering)
    .onTapGesture(perform: toggle)
  }

  private func sessionRow(
    _ session: ChatSession,
    isDragPreview: Bool = false,
    hierarchyDepth: Int = 0,
    isArchivedEntry: Bool = false,
    activatesOnMouseDown: Bool = true
  ) -> some View {
    let isSelected =
      !isDragPreview
      && !isArchivedEntry
      && selection == .session(serverId: session.serverId, id: session.id)
    return SidebarSessionRow(
      session: session,
      store: store,
      isDragPreview: isDragPreview,
      hierarchyDepth: hierarchyDepth,
      isArchivedEntry: isArchivedEntry,
      activatesOnMouseDown: activatesOnMouseDown,
      isSelected: isSelected,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      hierarchyIndent: hierarchyIndent,
      machineName: environment.machines.fleetMachineName(for: session.serverId),
      isUnread: { isUnread(session) },
      onActivate: { activateSession(session) },
      onRestoreRequest: { restoreRequest = ArchivedRestoreRequest(target: .session(session)) },
      onRename: {
        renameTitle = session.title
        renamingSession = session
      },
      onArchive: { archiveChat(session) },
      onMarkRead: { store?.markRead(session) },
      onMarkUnread: {
        store?.markUnread(session)
        if selection == .session(serverId: session.serverId, id: session.id) {
          selectNextChat(excluding: [session.id], serverId: session.serverId)
        }
      }
    )
  }

  /// Moves the selection off a chat that is leaving the screen (archive,
  /// mark-as-unread) to the most recent OTHER active chat. Only when none
  /// remain does the empty fallback create a fresh scratch workspace.
  func selectNextChat(excluding excluded: Set<UUID>, serverId: String) {
    let next = environment.projectList.sessions
      .filter { $0.serverId == serverId && !$0.isArchived && !excluded.contains($0.id) }
      .max { ($0.updatedAt ?? $0.createdAt) < ($1.updatedAt ?? $1.createdAt) }
    selection = next.map { .session(serverId: $0.serverId, id: $0.id) }
  }

  func chronologicalSessionRow(
    _ session: ChatSession,
    project: Project,
    isDragPreview: Bool = false,
    isArchivedEntry: Bool = false,
    isNested: Bool = false
  ) -> some View {
    let isSelected =
      !isDragPreview
      && !isArchivedEntry
      && selection == .session(serverId: session.serverId, id: session.id)
    // Manual-order chat rows attach this gesture alongside their native
    // drag source so activation does not prevent drag-to-reorder.
    return SidebarChronologicalSessionRow(
      session: session,
      project: project,
      store: store,
      isDragPreview: isDragPreview,
      isArchivedEntry: isArchivedEntry,
      hierarchyDepth: isNested ? 1 : 0,
      hierarchyIndent: hierarchyIndent,
      showsProjectName: !isNested || organization != .byProject,
      isSelected: isSelected,
      activatesOnMouseDown: order != .none,
      isReordering: isReordering,
      titleFont: itemTitleFont,
      isUnread: { isUnread(session) },
      onActivate: { activateSession(session) },
      onRestoreRequest: { restoreRequest = ArchivedRestoreRequest(target: .session(session)) },
      onRename: {
        renameTitle = session.title
        renamingSession = session
      },
      onArchive: { archiveChat(session) },
      onMarkRead: { store?.markRead(session) },
      onMarkUnread: {
        store?.markUnread(session)
        if selection == .session(serverId: session.serverId, id: session.id) {
          selectNextChat(excluding: [session.id], serverId: session.serverId)
        }
      }
    )
  }

  private func isProjectVisuallyExpanded(_ id: String) -> Bool {
    draggingProjectID == nil && expanded.contains(id)
  }

  private func toggle(_ id: String) {
    withAnimation(.snappy(duration: 0.28)) {
      if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
    }
  }

  /// Activate a chat as soon as the primary pointer goes down. Keeping this
  /// as a row gesture (rather than an overlay) preserves child button and
  /// context-menu hit testing.
  private func sessionActivationGesture(_ session: ChatSession) -> some Gesture {
    DragGesture(minimumDistance: 0)
      .onChanged { _ in
        activateSession(session)
      }
  }

  func activateSession(_ session: ChatSession) {
    // Restoring/opening a chat whose workspace was archived revives the
    // workspace — layout intact. Routed through the environment so the
    // revival reaches the server too; a bare local save left other
    // devices (and the server's cascade) believing it was still archived.
    if let workspaceId = environment.workspaces.workspaceId(forSession: session.id),
      let workspace = environment.workspaces.workspace(id: workspaceId),
      workspace.isArchived
    {
      environment.unarchiveWorkspace(workspace)
      workspaceRevision += 1
    }
    let target = SidebarSelection.session(serverId: session.serverId, id: session.id)
    guard selection != target else { return }
    // A route owns its machine identity. Opening a chat on another machine
    // is the same synchronous selection change as opening a sibling chat;
    // its controller resolves that machine's client independently.
    selection = target
  }

  @ViewBuilder
  private func reorderableSessionRow(_ session: ChatSession) -> some View {
    if order == .none {
      sessionRow(session, activatesOnMouseDown: false)
        .onDrag(
          { sessionDragItemProvider(for: session) },
          preview: {
            sessionRow(session, isDragPreview: true)
              .frame(width: 260)
          }
        )
        .simultaneousGesture(sessionActivationGesture(session))
        .opacity(draggingSessionID == session.id ? 0 : 1)
        .onDrop(
          of: [.text],
          delegate: SessionDropDelegate(
            sessionID: session.id,
            draggingSessionID: $draggingSessionID,
            moveSession: moveSession
          )
        )
    } else {
      sessionRow(session)
    }
  }

  @ViewBuilder
  func reorderableChronologicalSessionRow(
    _ session: ChatSession,
    project: Project,
    isNested: Bool = false
  ) -> some View {
    if order == .none {
      chronologicalSessionRow(session, project: project, isNested: isNested)
        .onDrag(
          { sessionDragItemProvider(for: session) },
          preview: {
            chronologicalSessionRow(
              session,
              project: project,
              isDragPreview: true,
              isNested: isNested
            )
            .frame(width: 260)
          }
        )
        .simultaneousGesture(sessionActivationGesture(session))
        .opacity(draggingSessionID == session.id ? 0 : 1)
        .onDrop(
          of: [.text],
          delegate: SessionDropDelegate(
            sessionID: session.id,
            draggingSessionID: $draggingSessionID,
            moveSession: moveSession
          )
        )
    } else {
      chronologicalSessionRow(session, project: project, isNested: isNested)
    }
  }

  private func sessionDragItemProvider(for session: ChatSession) -> NSItemProvider {
    draggingSessionID = session.id
    return NSItemProvider(object: session.id.uuidString as NSString)
  }
}
