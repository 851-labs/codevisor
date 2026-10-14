import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

extension HomeView {
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
    let workspaceId =
      environment.workspaces.workspaceId(forSession: session.id)
      ?? ensureWorkspace(for: session).id
    IOSNavigationDiagnostics.record(
      "home.openChat",
      "workspace=\(shortID(workspaceId)) session=\(shortID(session.id)) pathBefore=\(navigationPathSummary(path))"
    )
    openRoute(
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
        worktreeName: session.worktreeName,
        assignedWorkspaceId: projectList.workspaceId(forSession: session.id)
      ),
      legacyGroups: environment.paneGroups
    )
  }

  func applyPresentedWorkspaceDisposition(_ disposition: WorkspaceRouteDisposition) {
    guard case let .workspace(serverId, workspaceId, anchorSessionId, _, _, _)? = path.last else {
      return
    }
    IOSNavigationDiagnostics.record(
      "home.routeDisposition",
      "value=\(routeDispositionSummary(disposition)) workspace=\(shortID(workspaceId)) anchor=\(anchorSessionId.map(shortID) ?? "nil") pathBefore=\(navigationPathSummary(path))"
    )
    switch disposition {
    case .keep:
      break
    case let .selectSession(sessionId):
      guard sessionId != anchorSessionId else { return }
      navigation.replaceTop(
        with: .workspace(
          serverId: serverId,
          workspaceId: workspaceId,
          anchorSessionId: sessionId,
          preferredChatSessionId: sessionId
        )
      )
    case .dismiss:
      newChatFlow = nil
      if layoutMode == .split {
        selectDetail(nil)
      } else {
        path.removeAll()
      }
    }
  }

  func projectName(for session: ChatSession) -> String? {
    guard
      let project = projectList.projects.first(where: {
        $0.serverId == session.serverId && $0.id == session.projectId
      }),
      !project.isScratch
    else { return nil }
    return project.name
  }

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
}
