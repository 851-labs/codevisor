import CodevisorClient
import CodevisorCore
import CodevisorUI
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

  private struct RefreshKey: Equatable {
    let workspaceId: UUID
    let tab: WorkspaceInspectorTab
    let activity: Date?
  }

  static let presentedKey = "workspace.inspectorPresented"

  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(FeatureFlag.workspaceInspector.preferenceKey, default: false) private var isEnabled
  @ClientPreference(Self.presentedKey, default: true) private var isPresented
  @ClientPreference("workspace.inspectorTab", default: WorkspaceInspectorTab.info) private var tab
  @State private var media = WorkspaceInspectorMediaModel()
  @State private var fileTree = WorkspaceInspectorFileTreeModel()
  @State private var imageStores = WorkspaceInspectorImageStores()
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
          branch: store.gitLookups.branch(for: workspace),
          pullRequest: store.gitLookups.pullRequest(for: workspace),
          machineName: environment.machines.fleetMachineName(for: workspace.serverId),
          tab: $tab,
          media: media,
          fileTree: fileTree,
          client: environment.machines.client(for: workspace.serverId),
          onReload: { Task { await reload(workspace) } },
          onOpen: { destination in
            store.inspectorOpenRequest = WorkspaceInspectorOpenRequest(
              workspaceId: workspace.id, destination: destination)
          }
        )
        .environment(\.attachmentImages, imageStores.store(for: workspace.serverId, environment: environment))
        .task(id: RefreshKey(workspaceId: workspace.id, tab: tab, activity: activity(in: workspace))) {
          await reload(workspace)
        }
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

  private func reload(_ workspace: Workspace) async {
    let client = environment.machines.client(for: workspace.serverId)
    if tab == .files {
      await fileTree.show(root: workspace.rootDirectory, client: client)
    } else {
      await media.reload(tab, workspaceId: workspace.id, client: client)
    }
  }

  private func activity(in workspace: Workspace) -> Date? {
    environment.projectList.sessions
      .filter {
        $0.serverId == workspace.serverId && environment.workspaces.workspaceId(forSession: $0.id) == workspace.id
      }
      .map(\.sidebarStateChangedAt)
      .max()
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

@MainActor
final class WorkspaceInspectorImageStores {
  private var stores: [String: AttachmentImageStore] = [:]

  func store(for serverId: String, environment: AppEnvironment) -> AttachmentImageStore {
    if let existing = stores[serverId] { return existing }
    let client = { environment.machines.client(for: serverId) }
    let store = AttachmentImageStore(
      namespace: "\(serverId):workspace-media",
      fetch: { source in
        guard case let .attachment(fileId) = source else { throw CodevisorServerClientError.invalidResponse }
        return try await client().fileData(id: fileId)
      },
      fetchPreview: { source in
        guard case let .attachment(fileId) = source else { throw CodevisorServerClientError.invalidResponse }
        return try await client().filePreview(id: fileId)
      },
      version: { source in
        guard case let .attachment(fileId) = source else { return nil }
        return "attachment:\(fileId)"
      }
    )
    stores[serverId] = store
    return store
  }
}
