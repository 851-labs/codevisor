import Foundation
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI

struct PaneGroupFactory {
  let environment: AppEnvironment
  let browserPanes: BrowserPaneIndex
  weak var browserHost: SessionStore?

  func makeGroup(
    workspace: Workspace,
    session: ChatSession?,
    project: Project,
    leafId: UUID? = nil
  ) -> PaneGroupModel {
    let serverId = workspace.serverId
    let machine = machine(for: serverId, assumingLocal: session != nil)
    let repository = WorkspacePaneGroupRepository(
      workspaceId: workspace.id,
      groupId: leafId ?? session.flatMap { Self.leafId(containingChat: $0.id, in: workspace) },
      repository: environment.workspaces
    )
    let client = environment.machines.client(for: serverId)
    let model = PaneGroupModel(
      sessionId: session?.id,
      repository: repository,
      pluginIconClient: client,
      pluginIconCacheNamespace: serverId,
      makeContext: contextFactory(
        session: session, project: project, machine: machine, client: client, workspace: workspace)
    )
    model.browserIndex = browserPanes
    if let session {
      installBrowserHooks(on: model, session: session, project: project)
    }
    installSyncHooks(on: model, workspaceId: workspace.id, serverId: serverId)
    return model
  }

  func adopt(
    _ session: ChatSession,
    project: Project,
    workspace: Workspace,
    into model: PaneGroupModel
  ) {
    let serverId = workspace.serverId
    let machine = machine(for: serverId, assumingLocal: false)
    let client = environment.machines.client(for: serverId)
    model.adoptSession(
      session.id,
      makeContext: contextFactory(
        session: session, project: project, machine: machine, client: client, workspace: workspace))
    installBrowserHooks(on: model, session: session, project: project)
  }

  func retarget(
    _ model: PaneGroupModel,
    to workspace: Workspace,
    session: ChatSession,
    project: Project
  ) {
    let serverId = workspace.serverId
    let client = environment.machines.client(for: serverId)
    model.retarget(
      pluginIconClient: client,
      pluginIconCacheNamespace: serverId,
      makeContext: contextFactory(
        session: session, project: project, machine: machine(for: serverId, assumingLocal: false), client: client,
        workspace: workspace))
    if model.sessionId != nil {
      installBrowserHooks(on: model, session: session, project: project)
    }
    installSyncHooks(on: model, workspaceId: workspace.id, serverId: serverId)
  }

  private func machine(for serverId: String, assumingLocal: Bool) -> CodevisorMachine {
    if let machine = environment.machines.machine(for: serverId) { return machine }
    if assumingLocal || serverId == CodevisorMachine.local.id { return .local }
    return .unresolved(id: serverId)
  }

  private func installSyncHooks(on model: PaneGroupModel, workspaceId: UUID, serverId: String) {
    model.onPaneChanged = { [weak environment] pane in
      guard let environment else { return }
      environment.workspaceSync.publishPane(
        pane,
        workspaceId: workspaceId,
        client: environment.machines.client(for: serverId)
      )
    }
    model.isWorkspaceFinalPane = { [weak environment] pane in
      guard let liveWorkspace = environment?.workspaces.workspace(id: workspaceId) else {
        return false
      }
      return Self.isOnlyPane(pane, in: liveWorkspace)
    }
    model.onPaneRemoved = { [weak environment] pane in
      guard let environment, pane.kind != .subagent else { return }
      environment.workspaceSync.deletePane(
        id: pane.id,
        workspaceId: workspaceId,
        client: environment.machines.client(for: serverId)
      )
    }
  }

  private func installBrowserHooks(
    on model: PaneGroupModel,
    session: ChatSession,
    project: Project
  ) {
    model.openBrowserLink = { [weak browserHost] source, url, destination, popup in
      browserHost?.openBrowserLink(
        for: session, project: project, sourcePaneId: source, url: url, destination: destination,
        popup: popup
      ) ?? false
    }
    model.createBrowserTab = { [weak browserHost] url in
      browserHost?.createBrowserTab(for: session, project: project, url: url)
    }
  }

  private func contextFactory(
    session: ChatSession?,
    project: Project,
    machine: CodevisorMachine,
    client: (any CodevisorServerClienting)?,
    workspace: Workspace
  ) -> (PaneDescriptorState) -> PaneContext {
    let serverId = workspace.serverId
    let workspaceId = workspace.id
    let workspaceRootDirectory = workspace.rootDirectory
    return {
      [
        weak projectList = environment.projectList,
        weak machines = environment.machines
      ] descriptor in
      let liveSession = session.map { session in
        projectList?.session(session.id, serverId: session.serverId) ?? session
      }
      return PaneContext(
        paneId: descriptor.id,
        sessionId: session?.id,
        terminalKey: descriptor.terminalKey,
        machine: machine,
        session: liveSession,
        project: project,
        workspaceRootDirectory: workspaceRootDirectory,
        workspaceId: workspaceId,
        client: client,
        resolveHTTPBaseURL: {
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        },
        resolveServerConfig: {
          machines?.serverConfig(for: serverId) ?? machine.serverConfig
        },
        openTunnelMedia: {
          guard let route = await machines?.tunnelMediaRoute(forMachineId: serverId) else { return nil }
          return ScreenSharingTunnelMedia(
            endpointId: route.endpointId, flowId: Int(route.flowId), localPort: route.localPort,
            close: { route.close() })
        },
        openTunnelRoute: { await machines?.tunnelMediaRoute(forMachineId: serverId) }
      )
    }
  }

  private nonisolated static func leafId(containingChat chatId: UUID, in workspace: Workspace) -> UUID? {
    workspace.centerTabs.lazy.compactMap { $0.root.groupId(containingChat: chatId) }.first
  }

  private nonisolated static func isOnlyPane(_ pane: PaneDescriptorState, in workspace: Workspace) -> Bool {
    let panes = workspace.centerTabs.flatMap { tab in
      tab.root.allGroups.flatMap(\.state.panes)
    }
    return panes.count == 1 && panes[0].id == pane.id
  }
}
