import Foundation
import Observation
import CodevisorCore
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
  @ObservationIgnored var workspaceStepHandler: ((Int) -> Void)?
  @ObservationIgnored var isSidebarVisible = true
  @ObservationIgnored var closedPanes: [UUID: [ClosedPaneRecord]] = [:]
  static let maxClosedPanesPerWorkspace = 20

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
}
