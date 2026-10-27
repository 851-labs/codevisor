import CodevisorCore
import Foundation

@MainActor
@Observable
final class ChatControllerCache {
  static let shared = ChatControllerCache()

  private struct Key: Hashable {
    let serverId: String
    let id: UUID
  }

  @ObservationIgnored private var controllers: [Key: SessionController] = [:]
  @ObservationIgnored private var slots: [Key: ChatControllerSlot] = [:]
  private var draftsByServer: [String: SessionController] = [:]
  @ObservationIgnored private var scrollStates: [Key: SessionScrollState] = [:]
  @ObservationIgnored private var todoExpansionStates: [Key: Bool] = [:]
  @ObservationIgnored private var accessOrder: [Key] = []
  private static let maxIdleControllers = 8

  func controller(
    for session: ChatSession,
    project: Project,
    workspaceId: UUID,
    environment: AppEnvironment
  ) -> SessionController {
    let key = Key(serverId: session.serverId, id: session.id)
    noteAccess(key)
    if let existing = controllers[key] {
      if existing.project != project {
        existing.project = project
      }
      if existing.serverSession != session {
        IOSNavigationDiagnostics.record(
          "cache.configureExistingSession",
          "session=\(String(session.id.uuidString.prefix(8))) agent=\(session.agentSessionId?.isEmpty == false)"
        )
        existing.configureExistingSession(session)
      }
      return existing
    }
    let controller = SessionController(
      project: project,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      hostWorkspaceId: workspaceId,
      serverClient: environment.machines.client(for: session.serverId),
      machines: environment.machines,
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
    bindRetainedSessionState(controller, to: key)
    setController(controller, for: key)
    evictIfNeeded()
    return controller
  }

  func draftController(
    preferredProject: Project,
    environment: AppEnvironment
  ) -> SessionController {
    let serverId = preferredProject.serverId
    if let draft = draftsByServer[serverId], draft.serverSession == nil {
      return draft
    }
    if let draft = draftsByServer.values.first(where: {
      $0.serverSession == nil && $0.project.serverId == serverId
    }) {
      return draft
    }
    let persistedMatch =
      environment.composerDrafts.draft(forServer: serverId).map {
        (slotServerId: serverId, draft: $0)
      } ?? environment.composerDrafts.draft(targetingServer: serverId)
    let persisted = persistedMatch?.draft
    let slotServerId = persistedMatch?.slotServerId ?? serverId
    let restoredProject =
      persisted.flatMap { saved in
        var canonical = saved
        let savedServerId = saved.projectServerId ?? serverId
        canonical.projectServerId =
          environment.machines.canonicalComposerMachineId(for: savedServerId) ?? savedServerId
        return canonical.restoredProject(
          in: environment.projectList.projects, defaultServerId: serverId
        )
      } ?? environment.composerDefaults.lastProjectId(forServer: serverId).flatMap {
        rememberedId in
        environment.projectList.fleetActiveProjects.first {
          $0.serverId == serverId && $0.id == rememberedId && !$0.isScratch
        }
      } ?? preferredProject
    if !restoredProject.isRunTargetPlaceholder {
      environment.composerDefaults.rememberNewWorkspaceProject(
        serverId: restoredProject.serverId,
        projectId: restoredProject.id
      )
    }
    let controller = SessionController(
      project: restoredProject,
      configCache: environment.configCache,
      composerDefaults: environment.composerDefaults,
      serverClient: environment.machines.client(for: restoredProject.serverId),
      machines: environment.machines,
      attachmentFiles: environment.composerDrafts.attachmentFiles
    )
    controller.applyComposerDefaults()
    controller.wantsNewWorktree = environment.prefersNewWorktree(for: restoredProject)
    if let persisted { controller.restoreDraft(persisted) }
    controller.onDraftChange = { [weak drafts = environment.composerDrafts] draft in
      drafts?.saveDraft(draft, forServer: slotServerId)
    }
    environment.composerDrafts.saveDraft(controller.draftSnapshot(), forServer: slotServerId)
    draftsByServer[slotServerId] = controller
    return controller
  }

  func register(
    _ controller: SessionController,
    for session: ChatSession,
    environment: AppEnvironment
  ) {
    let key = Key(serverId: session.serverId, id: session.id)
    noteAccess(key)
    setController(controller, for: key)
    bindRetainedSessionState(controller, to: key)
    if let slotKey = draftsByServer.first(where: { $0.value === controller })?.key {
      draftsByServer[slotKey] = nil
      environment.composerDrafts.clearDraft(forServer: slotKey)
    } else {
      environment.composerDrafts.clearDraft(forServer: session.serverId)
    }
    controller.onDraftChange = nil
    evictIfNeeded()
  }

  func reregister(_ controller: SessionController, from previous: ChatSession, to relocated: ChatSession) {
    let old = Key(serverId: previous.serverId, id: previous.id)
    setController(nil, for: old)
    accessOrder.removeAll { $0 == old }
    let key = Key(serverId: relocated.serverId, id: relocated.id)
    noteAccess(key)
    setController(controller, for: key)
    bindRetainedSessionState(controller, to: key)
  }

  func existingController(sessionId: UUID, serverId: String) -> SessionController? {
    slot(Key(serverId: serverId, id: sessionId)).controller
  }

  func isInProgress(_ session: ChatSession) -> Bool {
    guard let controller = slot(Key(serverId: session.serverId, id: session.id)).controller else {
      return session.sidebarState == .inProgress
    }
    return controller.pendingUserMessage != nil
      || controller.isSending
      || controller.setupPhases.contains(where: \.isRunning)
      || controller.isWaitingOnBackgroundTasks
  }

  func reconcileInFlightControllers() async {
    await withTaskGroup(of: Void.self) { group in
      for controller in controllers.values where controller.isSending || controller.hasVisibleTranscript {
        group.addTask { await controller.reconcileInFlightTurn() }
      }
    }
  }

  private func slot(_ key: Key) -> ChatControllerSlot {
    if let existing = slots[key] { return existing }
    let created = ChatControllerSlot(controller: controllers[key])
    slots[key] = created
    return created
  }

  private func setController(_ controller: SessionController?, for key: Key) {
    controllers[key] = controller
    if let slot = slots[key], slot.controller !== controller { slot.controller = controller }
  }

  private func noteAccess(_ key: Key) {
    accessOrder.removeAll { $0 == key }
    accessOrder.append(key)
  }

  private func bindRetainedSessionState(_ controller: SessionController, to key: Key) {
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
  }

  private func evictIfNeeded() {
    var idle = accessOrder.filter { key in
      guard let controller = controllers[key] else { return false }
      if controller.isConnecting { return false }
      return !controller.isSending || controller.isTakingLongerThanExpected
    }
    while idle.count > Self.maxIdleControllers {
      let key = idle.removeFirst()
      let controller = controllers[key]
      setController(nil, for: key)
      controller?.onScrollStateChange = nil
      controller?.model?.shutdown()
      scrollStates[key] = nil
      accessOrder.removeAll { $0 == key }
    }
  }
}

@MainActor
@Observable
private final class ChatControllerSlot {
  var controller: SessionController?

  init(controller: SessionController?) {
    self.controller = controller
  }
}
