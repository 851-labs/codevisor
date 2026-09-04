import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

/// Opening chats, workspace routing, disclosure expansion, and the
/// no-machine / empty states.
extension HomeView {
  /// Agent rows always open the agent itself, never the terminal or sibling
  /// chat that happened to be selected when the workspace was last left.
  /// A notification tap lands here: switch to the chat's machine when
  /// needed, then open it — same contract as the macOS handler.
  func openNotificationSession(_ sessionId: UUID, serverId: String) {
    // Deliberately NO machine switch: routes carry the session's server
    // id end to end and the workspace gates on ITS machine, while
    // flipping the selected machine here put Home's list through a
    // catch-up loading state — a visible flicker on every tap of a chat
    // that lives on a non-selected machine.
    guard
      let session = projectList.sessions.first(where: {
        $0.serverId == serverId && $0.id == sessionId
      })
    else { return }
    openChat(session)
  }

  #if DEBUG || NAVIGATION_DIAGNOSTICS
    func openDiagnosticSession(_ id: UUID) {
      guard
        let session = projectList.sessions.first(where: {
          $0.serverId == environment.defaultComposerServerId && $0.id == id
        })
      else { return }
      IOSNavigationDiagnostics.record(
        "home.diagnosticOpenSession",
        "session=\(shortID(id))"
      )
      openChat(session)
    }
  #endif

  func openChat(_ session: ChatSession) {
    // Existing sessions take the O(1) index path. Only a legacy session
    // without a workspace pays the synchronous one-time backfill before
    // a routable destination id exists.
    let workspaceId =
      environment.workspaces.workspaceId(forSession: session.id)
      ?? ensureWorkspace(for: session).id
    IOSNavigationDiagnostics.record(
      "home.openChat",
      "workspace=\(shortID(workspaceId)) session=\(shortID(session.id)) pathBefore=\(navigationPathSummary(path))"
    )
    // Push first. Workspace pane selection, controller creation, history,
    // and transcript projection all begin from the destination's tasks.
    path.append(
      .workspace(
        serverId: session.serverId,
        workspaceId: workspaceId,
        anchorSessionId: session.id,
        preferredChatSessionId: session.id
      )
    )
  }

  func ensureWorkspace(for session: ChatSession) -> Workspace {
    let project = projectList.projects.first {
      $0.serverId == session.serverId && $0.id == session.projectId
    }
    return environment.workspaces.ensureWorkspace(
      for: WorkspaceSessionSeed(
        sessionId: session.id,
        initialName: session.worktreeName ?? project?.name ?? "Workspace",
        serverId: session.serverId,
        projectId: session.projectId,
        rootDirectory: session.cwd ?? project?.folderURL.path,
        worktreeName: session.worktreeName
      ),
      legacyGroups: environment.paneGroups
    )
  }

  func backfillWorkspacesIfNeeded() {
    guard organization == .byWorkspace else { return }

    let sessionsById = Dictionary(
      visibleSessions.map { ($0.id, $0) },
      uniquingKeysWith: { first, _ in first }
    )
    // Before workspaces were represented in the iOS navigator, sibling
    // chats lived only in the original chat's local pane payload. Process
    // the broadest layouts first so their shared workspace claims every
    // child before ordinary one-chat backfill runs.
    let legacyLayouts = visibleSessions.compactMap { session -> (ChatSession, [UUID])? in
      guard let state = WorkspacePaneStore.shared.existingState(for: session.id) else {
        return nil
      }
      var seen: Set<UUID> = []
      let chatIds = state.panes.compactMap { pane -> UUID? in
        guard pane.kind == .chat,
          let id = pane.chatSessionId,
          sessionsById[id] != nil,
          seen.insert(id).inserted
        else { return nil }
        return id
      }
      guard chatIds.count > 1, chatIds.contains(session.id) else { return nil }
      return (session, chatIds)
    }
    .sorted { $0.1.count > $1.1.count }

    for (anchor, chatIds) in legacyLayouts {
      var workspace = ensureWorkspace(for: anchor)
      var changed = false
      for chatId in chatIds where workspace.tabId(containingChat: chatId) == nil {
        workspace.centerTabs.append(
          WorkspaceTab(root: .leaf(.centerInitial(sessionId: chatId)))
        )
        changed = true
      }
      if changed { environment.workspaces.save(workspace) }
    }

    for session in visibleSessions {
      _ = ensureWorkspace(for: session)
    }
    workspaceRevision += 1
  }

  func setProject(_ id: UUID, isExpanded: Bool) {
    var ids = expandedProjectIDs
    if isExpanded { ids.insert(id) } else { ids.remove(id) }
    expandedProjectsRaw = ids.map(\.uuidString).sorted().joined(separator: "\n")
    toggleDisclosure {
      expandedProjectIDs = ids
    }
  }

  func setWorkspace(_ id: UUID, isExpanded: Bool) {
    var ids = expandedWorkspaces
    if isExpanded { ids.insert(id) } else { ids.remove(id) }
    let raw = ids.map(\.uuidString).sorted().joined(separator: "\n")
    toggleDisclosure {
      expandedWorkspacesRaw = raw
    }
  }

  /// Applies a disclosure change in an update pass of its own. The tap
  /// that toggles a row also ends the list's touch-hold gesture
  /// (`DragGesture(minimumDistance: 0)`), whose `@GestureState` reset lands
  /// in the same pass under its own, unanimated transaction; merged with
  /// the toggle, the List honored whichever transaction came first, so
  /// the open/close animation came and went at random. One turn later the
  /// toggle is alone in its pass and always animates.
  private func toggleDisclosure(_ change: @escaping @MainActor () -> Void) {
    Task { @MainActor in
      withAnimation(.snappy(duration: 0.28)) {
        change()
      }
    }
  }

  /// Shared Core policy decides whether the current route remains valid,
  /// moves to a surviving sibling chat, or leaves the workspace entirely.
  var presentedWorkspaceDisposition: WorkspaceRouteDisposition {
    _ = environment.workspaceSync.revision
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _)? = path.last else {
      return .keep
    }
    return environment.workspaceSync.routeDisposition(
      workspaceId: workspaceId,
      anchorSessionId: anchorSessionId,
      serverId: serverId
    )
  }

  func applyPresentedWorkspaceDisposition(_ disposition: WorkspaceRouteDisposition) {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _)? = path.last else {
      return
    }
    IOSNavigationDiagnostics.record(
      "home.routeDisposition",
      "value=\(routeDispositionSummary(disposition)) workspace=\(shortID(workspaceId)) anchor=\(shortID(anchorSessionId)) pathBefore=\(navigationPathSummary(path))"
    )
    switch disposition {
    case .keep:
      break
    case let .selectSession(sessionId):
      guard sessionId != anchorSessionId else { return }
      path[path.count - 1] = .workspace(
        serverId: serverId,
        workspaceId: workspaceId,
        anchorSessionId: sessionId,
        preferredChatSessionId: sessionId
      )
    case .dismiss:
      // WorkspaceScreen may currently have a pane cover above it;
      // clearing the owning stack closes the whole workspace and
      // returns to the navigation list in one state transition.
      newChatFlow = nil
      path.removeAll()
    }
  }

  /// The chat's project name for its row; nil for a no-project chat, whose
  /// scratch folder's generated name says nothing about it.
  func projectName(for session: ChatSession) -> String? {
    guard
      let project = projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      }),
      !project.isScratch
    else { return nil }
    return project.name
  }

  /// Fallback SF symbol from the machine's cached capabilities, for
  /// harnesses without a bundled brand icon.
  func harnessSymbol(for session: ChatSession) -> String {
    environment.configCache.capabilities(forServer: session.serverId)
      .first { $0.harness.id == session.harnessId }?
      .harness.symbolName ?? "cpu"
  }

  /// No machine paired (all machines removed): everything routes back
  /// into the onboarding connect page.
  var noMachineState: some View {
    ContentUnavailableView {
      Label {
        Text("No Machine Connected")
      } icon: {
        Image("hunk")
          .resizable()
          .scaledToFit()
          .frame(width: 52, height: 52)
          .foregroundStyle(.tertiary)
      }
    } description: {
      Text("Codevisor runs coding agents on your own Mac or Linux machine and streams them here.")
    } actions: {
      Button {
        onboardingStart = .connect
        onboardingDismissed = false
      } label: {
        Text("Connect a Machine")
          .font(.body.weight(.semibold))
          .foregroundStyle(.white)
          .padding(.horizontal, 14)
          .padding(.vertical, 4)
      }
      .buttonStyle(.borderedProminent)
      .buttonBorderShape(.capsule)
    }
  }

  /// Mail-style empty state: the navigation title already supplies the
  /// context, so the body needs only a quiet confirmation that it is empty.
  var emptyState: some View {
    Text("No \(organization.title)")
      .font(.title3.weight(.bold))
      .frame(maxWidth: .infinity, maxHeight: .infinity)
  }
}
