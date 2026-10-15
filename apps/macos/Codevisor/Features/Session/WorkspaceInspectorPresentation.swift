import CodevisorCore
import SwiftUI

struct WorkspaceInspectorOpenRequest: Equatable {
  let id = UUID()
  let workspaceId: UUID
  let destination: WorkspaceInspectorView.Destination
}

struct WorkspaceInspectorPresentation: ViewModifier {
  private struct Inspected {
    let workspace: Workspace
    let project: Project
  }

  static let presentedKey = "workspace.inspectorPresented"

  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(FeatureFlag.workspaceInspector.preferenceKey, default: false) private var isEnabled
  @ClientPreference(Self.presentedKey, default: true) private var isPresented
  let store: SessionStore?
  let selection: SidebarSelection?

  func body(content: Content) -> some View {
    let inspected = inspectedWorkspace
    content.inspector(
      isPresented: Binding(
        get: { isEnabled && isPresented && inspected != nil },
        set: { isPresented = $0 }
      )
    ) {
      if isEnabled, let store, let inspected {
        let workspace = inspected.workspace
        WorkspaceInspectorView(
          workspace: workspace,
          project: inspected.project,
          branch: store.branches.byWorkspace[workspace.id],
          pullRequest: store.pullRequests.byWorkspace[workspace.id],
          machineName: environment.machines.fleetMachineName(for: workspace.serverId),
          supportsDesktop: environment.machines.statusByMachineId[workspace.serverId]?.supportsScreenSharing == true,
          onOpen: { destination in
            store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(
              workspaceId: workspace.id, destination: destination)
          }
        )
        .inspectorColumnWidth(min: 220, ideal: 260, max: 400)
        .toolbar {
          ToolbarSpacer(.flexible)
          ToolbarItem {
            Button {
              isPresented.toggle()
            } label: {
              Label(isPresented ? "Hide Inspector" : "Show Inspector", systemImage: "sidebar.trailing")
            }
            .help(isPresented ? "Hide Inspector" : "Show Inspector")
          }
        }
      }
    }
  }

  private var inspectedWorkspace: Inspected? {
    guard let store else { return nil }
    switch selection {
    case let .session(serverId, sessionId):
      guard let session = environment.projectList.session(sessionId, serverId: serverId),
        let project = project(serverId: serverId, id: session.projectId)
      else { return nil }
      let entry = environment.workspaces.workspaceId(forSession: sessionId).map {
        environment.navigationStore.workspaceEntries.entry($0)
      }
      return Inspected(workspace: entry?.workspace ?? store.workspace(for: session, project: project), project: project)
    case let .workspace(serverId, workspaceId):
      guard let workspace = environment.navigationStore.workspaceEntries.entry(workspaceId).workspace,
        workspace.serverId == serverId,
        let project = project(serverId: serverId, id: workspace.projectId)
      else { return nil }
      return Inspected(workspace: workspace, project: project)
    case .archivedWorkspace, .newChat, .none:
      return nil
    }
  }

  private func project(serverId: String, id: UUID) -> Project? {
    environment.projectList.projects.first { $0.serverId == serverId && $0.id == id }
  }
}
