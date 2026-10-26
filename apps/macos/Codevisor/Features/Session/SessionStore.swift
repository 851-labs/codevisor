import Foundation
import Observation
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import ACPKit

struct ClosedPaneRecord: Equatable {
  let descriptor: PaneDescriptorState
  let tabId: UUID
  let tabIndex: Int
}

struct NewCenterTabRequest: Equatable {
  let workspaceId: UUID
}

@MainActor
@Observable
final class SessionStore {
  struct SessionKey: Hashable {
    let serverId: String
    let sessionId: UUID

    init(serverId: String, sessionId: UUID) {
      self.serverId = serverId
      self.sessionId = sessionId
    }

    init(_ session: ChatSession) {
      self.init(serverId: session.serverId, sessionId: session.id)
    }
  }

  @ObservationIgnored var controllers: [SessionKey: SessionController] = [:]
  @ObservationIgnored var isConfirmingChatClose = false
  @ObservationIgnored var scrollStates: [SessionKey: SessionScrollState] = [:]
  @ObservationIgnored var transcriptSurfaces =
    TranscriptPresentationSurfaceCache()
  @ObservationIgnored var subagentMirrors: [SubagentPaneKey: SubagentMirror] = [:]
  struct SubagentPaneKey: Hashable {
    let workspaceId: UUID
    let paneId: UUID
  }
  @ObservationIgnored var todoExpansionStates: [SessionKey: Bool] = [:]
  struct CenterLeafKey: Hashable {
    let workspaceId: UUID
    let groupId: UUID
  }
  @ObservationIgnored var centerLeafGroups: [CenterLeafKey: PaneGroupModel] = [:]
  @ObservationIgnored let browserPanes = BrowserPaneIndex()
  @ObservationIgnored let gitLookups = SidebarGitLookups()
  @ObservationIgnored var draftsByServer: [String: SessionController] = [:]
  @ObservationIgnored var paneDrafts: [UUID: SessionController] = [:]
  var activityRevision = 0
  var openSessionKey: SessionKey?
  var attentionFocus = SessionAttentionWorkspaceFocus()
  var isWindowFocused = false
  var navigationWorkspaceId: UUID? {
    get { attentionFocus.workspaceId }
    set {
      guard newValue != attentionFocus.workspaceId else { return }
      attentionFocus.selectWorkspace(newValue)
      publishFocus()
    }
  }
  @ObservationIgnored var navigationRevision = 0
  var newCenterTabRequest: NewCenterTabRequest?
  var inspectorOpenRequest: WorkspaceInspectorOpenRequest?
  @ObservationIgnored private(set) var workspaceStepHandler: ((Int) -> Void)?
  @ObservationIgnored private var workspaceStepOwner: UUID?
  @ObservationIgnored var isSidebarVisible = true
  @ObservationIgnored var closedPanes: [UUID: [ClosedPaneRecord]] = [:]
  static let maxClosedPanesPerWorkspace = 20

  func setWorkspaceStepHandler(owner: UUID, _ handler: @escaping (Int) -> Void) {
    workspaceStepOwner = owner
    workspaceStepHandler = handler
  }

  func clearWorkspaceStepHandler(owner: UUID) {
    guard workspaceStepOwner == owner else { return }

    workspaceStepOwner = nil
    workspaceStepHandler = nil
  }

  func recordClosedPane(_ record: ClosedPaneRecord, workspaceId: UUID) {
    var stack = closedPanes[workspaceId, default: []]
    stack.append(record)
    if stack.count > Self.maxClosedPanesPerWorkspace {
      stack.removeFirst(stack.count - Self.maxClosedPanesPerWorkspace)
    }
    closedPanes[workspaceId] = stack
  }

  func popClosedPane(workspaceId: UUID) -> ClosedPaneRecord? {
    closedPanes[workspaceId]?.popLast()
  }
  @ObservationIgnored var accessOrder: [SessionKey] = []
  static let maxIdleControllers = 12
  let environment: AppEnvironment
  let notificationDelivery: any ChatNotificationDelivering

  init(
    environment: AppEnvironment,
    notificationDelivery: (any ChatNotificationDelivering)? = nil
  ) {
    self.environment = environment
    self.notificationDelivery = notificationDelivery ?? ChatNotificationManager.shared
    environment.onSessionStateChanged = { [weak self] session, revision in
      guard let controller = self?.controllers[SessionKey(session)] else { return }
      Task { await controller.reconcileServerSummary(session, revision: revision) }
    }
  }

  func controller(for session: ChatSession, project: Project) -> SessionController {
    let key = SessionKey(session)
    if let existing = controllers[key] {
      return existing
    }

    if session.agentSessionId?.isEmpty != false,
      let location = paneDraftLocation(for: session)
    {
      return paneDraft(
        paneId: location.paneId,
        project: project,
        preCreatedSession: session,
        workspaceId: location.workspaceId
      )
    }

    let workspaceId = environment.workspaces.workspaceId(forSession: session.id)
    let controller = SessionController(
      project: project,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      hostWorkspaceId: workspaceId,
      serverClient: environment.machines.client(for: session.serverId),
      machines: environment.machines,
      notificationDelivery: notificationDelivery,
      attachmentFiles: environment.composerDrafts.attachmentFiles
    )
    controller.transcriptCache = environment.transcriptCache
    controller.configureExistingSession(session)
    controller.onAgentSessionCreated = { [weak projectList = environment.projectList] agentSessionId in
      projectList?.setAgentSessionId(
        agentSessionId,
        for: session.id,
        serverId: session.serverId
      )
    }
    controller.scrollState = scrollStates[key]
    controller.onScrollStateChange = { [weak self] state in
      self?.scrollStates[key] = state
    }
    controller.restoreTodoDisclosure(
      isExpanded: todoExpansionStates[key] ?? false
    )
    controller.onTodosExpandedChange = { [weak self] isExpanded in
      self?.todoExpansionStates[key] = isExpanded
    }
    controller.onTurnEnded = { [weak self] in self?.noteTurnEnded() }
    controllers[key] = controller
    return controller
  }

  func transcriptSurface(
    for session: ChatSession,
    paneID: UUID,
    controller: SessionController
  ) -> TranscriptPresentationSurface {
    transcriptSurfaces.surface(
      for: .init(
        serverID: session.serverId,
        sessionID: session.id,
        paneID: paneID
      ),
      controller: controller
    )
  }

  func reconcile(
    _ controller: SessionController,
    for session: ChatSession,
    project: Project
  ) {
    guard activeController(for: session) === controller else { return }
    if controller.project != project {
      controller.project = project
    }
    controller.reconcileExistingSession(session)
  }

  func activeController(for session: ChatSession) -> SessionController? {
    if let controller = controllers[SessionKey(session)] {
      return controller
    }
    guard session.agentSessionId?.isEmpty != false,
      let location = paneDraftLocation(for: session)
    else { return nil }
    return paneDrafts[location.paneId]
  }

  @ObservationIgnored var ephemeralWorkspaces: [UUID: Workspace] = [:]

  private var paneGroupFactory: PaneGroupFactory {
    PaneGroupFactory(environment: environment, browserPanes: browserPanes, browserHost: self)
  }

  func centerPaneGroup(for session: ChatSession, project: Project) -> PaneGroupModel {
    let workspace = workspace(for: session, project: project)
    guard
      let leafId = workspace.centerTabs.lazy.compactMap({
        $0.root.groupId(containingChat: session.id)
      }).first
        ?? workspace.centerTree.allGroups.first?.id
    else {
      return paneGroupFactory.makeGroup(
        workspace: self.workspace(for: session, project: project), session: session, project: project)
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
        paneGroupFactory.adopt(session, project: project, workspace: workspace, into: existing)
      }
      return existing
    }
    let group = paneGroupFactory.makeGroup(
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

  func evictCenterLeaf(workspaceId: UUID, leafId: UUID) {
    centerLeafGroups[CenterLeafKey(workspaceId: workspaceId, groupId: leafId)] = nil
  }

  func localBrowserModel(paneId: UUID) -> ChromiumBrowserModel? {
    browserPanes.model(paneId: paneId)
  }

  func localBrowserTitle(paneId: UUID) -> String? {
    localBrowserModel(paneId: paneId)?.title
  }

  func canHostBackgroundBrowser(serverId: String, sessionId: String) -> Bool {
    backgroundBrowserTarget(serverId: serverId, sessionId: sessionId) != nil
  }

  func createBackgroundBrowserTab(serverId: String, sessionId: String, url: String) -> ChromiumBrowserModel? {
    guard let (session, project) = backgroundBrowserTarget(serverId: serverId, sessionId: sessionId) else {
      return nil
    }
    return createBrowserTab(for: session, project: project, url: url)
  }

  func createBrowserTab(
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
    browser.model.openAsNewTab(url)
    environment.workspaceSync.publishPane(
      descriptor, workspaceId: workspace.id,
      client: environment.machines.client(for: session.serverId)
    )
    return browser.model
  }

  private func backgroundBrowserTarget(serverId: String, sessionId: String) -> (ChatSession, Project)? {
    guard let id = UUID(uuidString: sessionId),
      let session = environment.projectList.session(id, serverId: serverId),
      let project = environment.projectList.projects.first(where: {
        $0.serverId == serverId && $0.id == session.projectId
      })
    else { return nil }
    return (session, project)
  }
}
