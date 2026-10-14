import Foundation
import Observation
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ACPKit

extension SessionStore {
  func localBrowserModel(paneId: UUID) -> ChromiumBrowserModel? {
    browserPanes.model(paneId: paneId)
  }

  func localBrowserTitle(paneId: UUID) -> String? {
    localBrowserModel(paneId: paneId)?.title
  }

  func centerPaneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
    let workspace = workspace(for: session, project: project)
    guard
      let leafId = workspace.centerTabs.lazy.compactMap({
        $0.root.groupId(containingChat: session.id)
      }).first
        ?? workspace.centerTree.allGroups.first?.id
    else {
      return makePaneGroup(for: session, project: project)
    }
    return centerGroup(leafId: leafId, workspace: workspace, session: session, project: project)
  }

  func workspace(for session: ChatSession, project: Project) -> Workspace {
    let seed = WorkspaceSessionSeed(
      sessionId: session.id,
      initialName: session.worktreeName ?? project.name,
      serverId: session.serverId,
      projectId: project.id,
      rootDirectory: session.cwd ?? project.folderURL.path,
      worktreeName: session.worktreeName,
      assignedWorkspaceId: environment.projectList.workspaceId(forSession: session.id)
    )
    if environment.workspaces.workspaceId(forSession: session.id) == nil,
      environment.projectList.session(session.id, serverId: session.serverId) == nil
    {
      if let cached = ephemeralWorkspaces[session.id] { return cached }
      let ephemeral = environment.workspaces.ephemeralWorkspace(for: seed)
      ephemeralWorkspaces[session.id] = ephemeral
      return ephemeral
    }
    return environment.workspaces.ensureWorkspace(
      for: seed,
      legacyGroups: environment.paneGroups
    )
  }

  func centerGroup(
    leafId: UUID,
    workspace: Workspace,
    session: ChatSession?,
    project: Project
  ) -> PaneGroupModel {
    let key = CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
    if let existing = centerLeafGroups[key] {
      if let session, existing.sessionId == nil {
        adoptSession(session, project: project, workspace: workspace, in: existing)
      }
      return existing
    }
    let group = makePaneGroup(
      workspace: workspace, session: session, project: project, leafId: leafId)
    centerLeafGroups[key] = group
    return group
  }

  @discardableResult
  func reconcileMountedPaneGroups(in workspace: Workspace) -> Bool {
    var changed = false

    let centerStates = Dictionary(
      uniqueKeysWithValues: workspace.centerTabs.flatMap { tab in
        tab.root.allGroups.map { ($0.id, $0.state) }
      }
    )
    var removedKeys: [CenterLeafKey] = []
    for (key, model) in centerLeafGroups where key.workspaceId == workspace.id {
      if let state = centerStates[key.groupId] {
        changed = model.reconcileExternalState(state) || changed
      } else {
        changed = model.reconcileExternalState(PaneGroupState()) || changed
        removedKeys.append(key)
      }
    }
    for key in removedKeys {
      centerLeafGroups[key] = nil
    }
    pruneSubagentMirrors(in: workspace)
    return changed
  }

  func makePaneGroup(
    for session: ChatSession,
    project: Project,
    leafId: UUID? = nil
  ) -> PaneGroupModel {
    makePaneGroup(
      workspace: workspace(for: session, project: project), session: session, project: project,
      leafId: leafId)
  }

  func makePaneGroup(
    workspace: Workspace,
    session: ChatSession?,
    project: Project,
    leafId: UUID? = nil
  ) -> PaneGroupModel {
    let serverId = workspace.serverId
    let machine =
      environment.machines.machine(for: serverId)
      ?? (session != nil || serverId == CodevisorMachine.local.id
        ? CodevisorMachine.local : CodevisorMachine.unresolved(id: serverId))
    let resolvedLeafId =
      leafId
      ?? session.flatMap { session in
        workspace.centerTabs.lazy.compactMap {
          $0.root.groupId(containingChat: session.id)
        }.first
      }
    let repository = WorkspacePaneGroupRepository(
      workspaceId: workspace.id,
      groupId: resolvedLeafId,
      repository: environment.workspaces
    )
    let client = environment.machines.client(for: serverId)
    let workspaceIdForPanes = workspace.id
    let workspaceRootDirectory = workspace.rootDirectory
    let model = PaneGroupModel(
      sessionId: session?.id,
      repository: repository,
      pluginIconClient: client,
      pluginIconCacheNamespace: serverId,
      makeContext: paneContextFactory(
        session: session, project: project, machine: machine, client: client, serverId: serverId,
        workspaceId: workspaceIdForPanes, workspaceRootDirectory: workspaceRootDirectory)
    )
    model.browserIndex = browserPanes
    if let session {
      installBrowserHooks(on: model, session: session, project: project)
    }
    model.onPaneChanged = { [weak environment] pane in
      guard let environment else { return }
      environment.workspaceSync.publishPane(
        pane,
        workspaceId: workspaceIdForPanes,
        client: environment.machines.client(for: serverId)
      )
    }
    let workspaceId = workspace.id
    model.shouldReplaceClosedPaneWithNewTab = { [weak environment] pane in
      guard let liveWorkspace = environment?.workspaces.workspace(id: workspaceId) else {
        return false
      }
      let panes =
        liveWorkspace.centerTabs.flatMap { tab in
          tab.root.allGroups.flatMap(\.state.panes)
        }
      return panes.count == 1 && panes[0].id == pane.id
    }
    model.onPaneRemoved = { [weak environment] pane, replacement in
      guard let environment, pane.kind != .subagent else { return }
      environment.workspaceSync.deletePane(
        id: pane.id,
        workspaceId: workspaceId,
        optimisticReplacement: replacement,
        client: environment.machines.client(for: serverId)
      )
    }
    return model
  }

  private func paneContextFactory(
    session: ChatSession?,
    project: Project,
    machine: CodevisorMachine,
    client: (any CodevisorServerClienting)?,
    serverId: String,
    workspaceId: UUID,
    workspaceRootDirectory: String?
  ) -> (PaneDescriptorState) -> PaneContext {
    {
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

  private func adoptSession(
    _ session: ChatSession,
    project: Project,
    workspace: Workspace,
    in model: PaneGroupModel
  ) {
    let serverId = workspace.serverId
    let machine =
      environment.machines.machine(for: serverId)
      ?? (serverId == CodevisorMachine.local.id
        ? CodevisorMachine.local : CodevisorMachine.unresolved(id: serverId))
    let client = environment.machines.client(for: serverId)
    model.adoptSession(
      session.id,
      makeContext: paneContextFactory(
        session: session, project: project, machine: machine, client: client, serverId: serverId,
        workspaceId: workspace.id, workspaceRootDirectory: workspace.rootDirectory))
    installBrowserHooks(on: model, session: session, project: project)
  }

  private func installBrowserHooks(
    on model: PaneGroupModel,
    session: ChatSession,
    project: Project
  ) {
    model.openBrowserLink = { [weak self] source, url, destination, popup in
      self?.openBrowserLink(
        for: session, project: project, sourcePaneId: source, url: url, destination: destination,
        popup: popup
      ) ?? false
    }
    model.createBrowserTab = { [weak self] url in
      self?.createBrowserTab(for: session, project: project, url: url)
    }
  }

  private func createBrowserTab(
    for session: ChatSession, project: Project, url: String
  ) -> ChromiumBrowserModel? {
    var workspace = workspace(for: session, project: project)
    let paneId = UUID()
    let descriptor = PaneDescriptorState(
      id: paneId, kind: .browser, name: "Browser", terminalKey: paneId.uuidString,
      browserURL: BrowserLocation.sharedURL(url)?.absoluteString
    )
    let tabId = workspace.upsertCenterPane(descriptor, selecting: false)
    environment.workspaces.save(workspace)
    guard let tab = workspace.centerTabs.first(where: { $0.id == tabId }) else { return nil }
    let group = centerGroup(
      leafId: tab.activeLeafId, workspace: workspace, session: session, project: project
    )
    guard let browser = group.pane(for: descriptor) as? BrowserPane else { return nil }
    browser.model.automationInitialURL = url
    environment.workspaceSync.publishPane(
      descriptor, workspaceId: workspace.id,
      client: environment.machines.client(for: session.serverId)
    )
    return browser.model
  }

  func evictCenterLeaf(workspaceId: UUID, leafId: UUID) {
    centerLeafGroups[CenterLeafKey(workspaceId: workspaceId, groupId: leafId)] = nil
  }
}
