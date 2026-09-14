import Foundation
import Observation
import CodevisorCore
import CodevisorUI
import ACPKit

// MARK: - PaneGroups

extension SessionStore {
  func localBrowserModel(paneId: UUID) -> ChromiumBrowserModel? {
    let groups = Array(centerLeafGroups.values)
    return groups.lazy.compactMap { ($0.live[paneId] as? BrowserPane)?.model }.first
  }

  func localBrowserTitle(paneId: UUID) -> String? {
    localBrowserModel(paneId: paneId)?.title
  }

  /// The center group hosting this session's chat: THE SAME model instance
  /// the split view renders for that leaf (one model per leaf, ever —
  /// duplicate instances would clobber each other's saves).
  func centerPaneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
    let workspace = workspace(for: session, project: project)
    guard
      let leafId = workspace.centerTabs.lazy.compactMap({
        $0.root.groupId(containingChat: session.id)
      }).first
        ?? workspace.centerTree.allGroups.first?.id
    else {
      // Unreachable (a workspace always has a leaf); satisfies the
      // optional without a second cache.
      return makePaneGroup(for: session, project: project)
    }
    return centerGroup(leafId: leafId, workspace: workspace, session: session, project: project)
  }

  /// The workspace owning this session's chat, created (backfilled from
  /// the session + any pre-workspace pane state) on first access.
  func workspace(for session: ChatSession, project: Project) -> Workspace {
    let seed = WorkspaceSessionSeed(
      sessionId: session.id,
      initialName: session.worktreeName ?? project.name,
      serverId: session.serverId,
      projectId: project.id,
      rootDirectory: session.cwd ?? project.folderURL.path,
      worktreeName: session.worktreeName,
      assignedWorkspaceId: environment.projectList.workspaceAssignments(for: session.serverId)[session.id]
    )
    // A chat that is no longer active and has NO persisted workspace must
    // not mint one: archiving a scratch chat deletes its workspace (index
    // entry included), and the chat's still-mounted screen re-evaluates
    // during the teardown transition — persisting here resurrected the
    // just-deleted workspace as a zombie sidebar row. Hand such screens a
    // stable ephemeral stand-in instead.
    if environment.workspaces.workspaceId(forSession: session.id) == nil,
      !environment.projectList.sessions.contains(where: {
        $0.serverId == session.serverId && $0.id == session.id && !$0.isArchived
      })
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

  /// Persists a divider drag: the workspace's center tree with updated
  /// fractions (same topology).
  func saveCenterTree(_ tree: SplitNode, workspaceId: UUID) {
    guard var workspace = environment.workspaces.workspace(id: workspaceId) else { return }
    workspace.centerTree = tree
    environment.workspaces.save(workspace)
  }

  /// A specific center-tree LEAF's group model (split groups beyond the
  /// primary). Cached per (workspace, leaf) so panes survive navigation.
  /// `session` is nil for a workspace that has never hosted a chat: the leaf
  /// still has its own persisted layout, keyed by workspace and leaf.
  func centerGroup(
    leafId: UUID,
    workspace: Workspace,
    session: ChatSession?,
    project: Project
  ) -> PaneGroupModel {
    let key = CenterLeafKey(workspaceId: workspace.id, groupId: leafId)
    if let existing = centerLeafGroups[key] {
      // The same leaf can be entered first without a chat and later with one.
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

  /// Pushes repository truth into pane models that are already mounted.
  /// Workspace sync owns the repository write; these model updates are a
  /// non-persisting presentation reconciliation so they cannot echo remote
  /// changes back to the server.
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
    return changed
  }

  /// Unchanged entry point for every session-rooted call site: it resolves the
  /// session's workspace (backfilling pre-workspace state on first access) and
  /// then runs the same shared implementation a chatless workspace uses.
  func makePaneGroup(
    for session: ChatSession,
    project: Project,
    leafId: UUID? = nil
  ) -> PaneGroupModel {
    makePaneGroup(
      workspace: workspace(for: session, project: project), session: session, project: project,
      leafId: leafId)
  }

  /// The shared implementation. The WORKSPACE supplies identity (server,
  /// persistence, publication); the session, when there is one, supplies chat
  /// affordances: the leaf that hosts its chat, the pane context's session and
  /// the browser link/automation hooks.
  func makePaneGroup(
    workspace: Workspace,
    session: ChatSession?,
    project: Project,
    leafId: UUID? = nil
  ) -> PaneGroupModel {
    let serverId = workspace.serverId
    // A session mount keeps its historical fallback. A workspace mount must not:
    // substituting `.local` for an unresolved REMOTE machine would quietly move
    // that workspace's terminals and screen sharing onto this Mac. Unavailable
    // is the correct answer, under the workspace's own server id.
    let machine =
      environment.machines.machine(for: serverId)
      ?? (session != nil || serverId == CodevisorMachine.local.id
        ? CodevisorMachine.local : CodevisorMachine.unresolved(id: serverId))
    // Center groups pin to a specific tree leaf: the given one, else the leaf
    // hosting this session's chat (a workspace without a chat has only the
    // given leaf).
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
    // The workspace's own working directory anchors panes that have no chat.
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
    // Browser links and automation are chat-rooted: they open next to a real
    // session. A workspace without one leaves both hooks nil, which is also
    // what makes `canHostBrowserAutomation` decline for its panes.
    if let session {
      installBrowserHooks(on: model, session: session, project: project)
    }
    model.onPaneChanged = { [weak self, weak environment] pane in
      // A pane changing IN PLACE — a New Tab becoming Screen Sharing, a rename,
      // a draft binding its chat — is a local layout write just like adding or
      // closing a tab, and the descriptor is already persisted by the time this
      // runs. Bump the same token those structural writes use so the sidebar
      // re-reads the repository now; otherwise its row keeps the previous name
      // until an unrelated sync revision happens to arrive, because
      // `centerLeafGroups` is deliberately not observable and a row rendered
      // before this leaf's model existed holds no dependency on it.
      self?.workspaceLayoutRevision += 1
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
      guard let environment else { return }
      environment.workspaceSync.deletePane(
        id: pane.id,
        workspaceId: workspaceId,
        optimisticReplacement: replacement,
        client: environment.machines.client(for: serverId)
      )
    }
    return model
  }

  /// One definition of a pane's context, used when a group is created and again
  /// when a chatless group adopts the chat that later appears in its leaf.
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
      // Panes are built lazily, so this cached closure can outlive the snapshot
      // passed in above: a fresh worktree session may not have synced its cwd
      // yet. Resolve the live session at pane-creation time so terminals open in
      // the worktree, not the project folder.
      let liveSession = session.map { session in
        projectList?.sessions.first {
          $0.serverId == session.serverId && $0.id == session.id
        } ?? session
      }
      return PaneContext(
        paneId: descriptor.id,
        sessionId: session?.id,
        terminalKey: descriptor.terminalKey,
        attachOnly: descriptor.attachOnly,
        machine: machine,
        session: liveSession,
        project: project,
        workspaceRootDirectory: workspaceRootDirectory,
        workspaceId: workspaceId,
        client: client,
        resolveHTTPBaseURL: {
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        }
      )
    }
  }

  /// Upgrades a cached group that was built for a workspace with no chat once a
  /// real chat exists in its leaf. The model, its live panes and its persisted
  /// state are kept; only the identity, the context factory and the chat-rooted
  /// browser hooks are (re)established. Without this the cached group would keep
  /// a nil identity forever and leave terminals, browser automation and
  /// file-backed panes unavailable in a workspace that now has a chat.
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

  /// The chat-rooted browser hooks, shared by creation and adoption.
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

  /// Browser Use appends a workspace tab in the background, like a pane
  /// arriving from another device. The user's selected tab and focus stay put.
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
    workspaceLayoutRevision += 1
    return browser.model
  }

  /// Drops a dissolved leaf's cached model (its panes have already moved
  /// elsewhere — nothing to detach).
  func evictCenterLeaf(workspaceId: UUID, leafId: UUID) {
    centerLeafGroups[CenterLeafKey(workspaceId: workspaceId, groupId: leafId)] = nil
  }
}
