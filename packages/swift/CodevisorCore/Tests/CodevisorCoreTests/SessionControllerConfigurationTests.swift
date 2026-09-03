import Foundation
import Testing
import ACPKit
@testable import CodevisorCore

@MainActor
@Suite("SessionController configuration")
struct SessionControllerConfigurationTests {
  @Test("An onboarding capability warm replaces a provisional empty model snapshot")
  func onboardingWarmSuppliesModelsToMountedDraft() async {
    let cache = ConfigOptionCache(store: InMemoryStore())
    var mutableCapability = capability(model: "gpt-5.6")
    mutableCapability.configOptions[0].options.append(
      SessionConfigSelectOption(value: "gpt-5.6-terra", name: "GPT-5.6-Terra")
    )
    let warmedCapability = mutableCapability
    let client = SyncFakeServerClient(projects: [], sessions: [])
    client.resolvedCapabilitiesHandler = { _, _, selections in
      var resolved = warmedCapability
      resolved.configOptions[0].currentValue = selections["model"] ?? "gpt-5.6"
      return ServerCapabilities(harnesses: [resolved])
    }
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/tmp/project"),
      serverId: "machine-a"
    )
    cache.seedHarnesses([warmedCapability.harness], forServer: project.serverId)
    let controller = SessionController(
      project: project,
      configCache: cache,
      serverClient: client
    )

    // The draft mounted from onboarding's fast harness-only seed.
    #expect(controller.configOptionsByHarness[warmedCapability.harness.id]?.isEmpty == true)
    #expect(controller.modelOption == nil)

    // The speculative warm updates the observable shared cache without
    // directly applying another snapshot to this controller.
    cache.store([warmedCapability], forServer: project.serverId)

    #expect(controller.modelOption?.currentValue == "gpt-5.6")

    // This is the model-row click path from the recording. It must stage
    // and resolve the selected value even though the controller's older
    // harness snapshot is still empty.
    await controller.setConfigOption("model", "gpt-5.6-terra")

    #expect(controller.modelOption?.currentValue == "gpt-5.6-terra")
  }

  @Test("An in-flight capability refresh keeps a provisional catalog loading")
  func provisionalCatalogKeepsModelLoading() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let capability = capability(model: "gpt-5.6")
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/project")),
      configCache: cache
    )
    controller.harnesses = [capability.harness]
    controller.selectedHarnessId = capability.harness.id
    controller.preparationState = .ready
    controller.isRefreshingHarnessCapabilities = true

    #expect(controller.isRefreshingHarnessCapabilities)
    #expect(controller.isLoadingModelMenu)
    #expect(!controller.hasModelMenu)
  }

  @Test("Catalog invalidation keeps a mounted draft usable during refresh")
  func invalidationPreservesMountedDraft() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let capability = capability(model: "stale-model")
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/project")),
      configCache: cache
    )
    controller.harnesses = [capability.harness]
    controller.selectedHarnessId = capability.harness.id
    controller.configOptionsByHarness[capability.harness.id] = capability.configOptions
    controller.modeStateByHarness[capability.harness.id] = SessionModeState(
      currentModeId: "default",
      availableModes: [SessionMode(id: "default", name: "Default")]
    )
    controller.supportsGoalsByHarness[capability.harness.id] = true
    controller.preparationState = .ready

    #expect(controller.hasModelMenu)
    controller.invalidateHarnessCapabilities()

    #expect(controller.harnesses == [capability.harness])
    #expect(controller.configOptions == capability.configOptions)
    #expect(controller.modeState?.currentModeId == "default")
    #expect(controller.supportsGoals)
    #expect(controller.preparationState == .ready)
    #expect(controller.isRefreshingHarnessCapabilities)
    #expect(!controller.isLoadingModelMenu)
  }

  @Test("A connected runtime with no options falls back to the cached catalog")
  func connectedRuntimeWithoutOptionsUsesCachedCatalog() {
    let cache = ConfigOptionCache(store: InMemoryStore())
    let capability = capability(model: "opus[1m]")
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/project"))
    cache.store([capability], forServer: project.serverId)
    let controller = SessionController(project: project, configCache: cache)
    controller.harnesses = [capability.harness]
    controller.selectedHarnessId = capability.harness.id
    controller.connectedHarnessId = capability.harness.id
    controller.preparationState = .ready
    let sessionId = UUID()
    // Claude's runtime reports NO options when its model list loses the
    // startup race, and publishes the list later as a config update.
    let model = SessionModel(
      serverTransport: ServerSessionTransport(
        client: FakeSessionServerClient(sessionId: sessionId),
        sessionId: sessionId
      ),
      sessionId: sessionId.uuidString,
      configOptions: []
    )
    controller.model = model

    #expect(controller.configOptions == capability.configOptions)
    #expect(controller.modelOption?.currentValue == "opus[1m]")
    #expect(controller.hasModelMenu)
    #expect(!controller.isLoadingModelMenu)

    // The late list replaces the cached stand-in.
    var live = capability.configOptions
    live[0].currentValue = "sonnet"
    live[0].options = [SessionConfigSelectOption(value: "sonnet", name: "Sonnet")]
    model.applyRuntimeMetadata(modeState: nil, configOptions: live)
    #expect(controller.configOptions == live)
    #expect(controller.modelOption?.currentValue == "sonnet")
  }

  @Test("Remote attention metadata does not republish the controller session")
  func ignoresPresentationOnlySessionUpdates() {
    let original = session()
    let controller = controller(for: original)
    var attentionUpdate = original
    attentionUpdate.title = "Renamed remotely"
    attentionUpdate.origin = .imported
    attentionUpdate.isArchived = true
    attentionUpdate.archivedAt = Date(timeIntervalSince1970: 200)
    attentionUpdate.createdAt = Date(timeIntervalSince1970: 100)
    attentionUpdate.updatedAt = Date(timeIntervalSince1970: 300)
    attentionUpdate.sidebarState = .waitingForUser
    attentionUpdate.sidebarStateChangedAt = Date(timeIntervalSince1970: 300)
    attentionUpdate.latestAttentionSequence = 8
    attentionUpdate.lastSeenAttentionSequence = 3
    attentionUpdate.unreadCount = 5
    attentionUpdate.hasUnreadError = true
    attentionUpdate.actionRequired = true
    attentionUpdate.actionRequiredKind = "approval"
    attentionUpdate.pendingPlanApproval = true

    #expect(!controller.reconcileExistingSession(attentionUpdate))
    #expect(controller.serverSession == original)
  }

  @Test("Remote runtime changes are adopted by the controller")
  func adoptsRuntimeSessionUpdates() {
    let original = session()
    let updates: [(inout ChatSession) -> Void] = [
      { $0.id = UUID() },
      { $0.projectId = UUID() },
      { $0.serverId = "remote-b" },
      { $0.harnessId = "claude-code" },
      { $0.harnessAccountId = "work" },
      { $0.agentSessionId = "agent-2" },
      { $0.worktreeName = "fix/crash" },
      { $0.cwd = "/remote/project-worktree" },
      { $0.configSelections = ["model": "gpt-5.6"] },
    ]

    for update in updates {
      let controller = controller(for: original)
      var changed = original
      update(&changed)

      #expect(controller.reconcileExistingSession(changed))
      #expect(controller.serverSession == changed)
    }
  }

  @Test("Reconciliation configures an unbound controller")
  func configuresUnboundController() {
    let session = session()
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/remote/project"),
      id: session.projectId,
      serverId: session.serverId
    )
    let controller = SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore())
    )

    #expect(controller.reconcileExistingSession(session))
    #expect(controller.serverSession == session)
    #expect(controller.selectedHarnessId == session.harnessId)
  }

  @Test("Retargeting a draft swaps its project AND its machine, keeping the composer")
  func retargetSwapsMachine() async {
    let homeProject = Project.fromFolder(
      URL(fileURLWithPath: "/tmp/home-work")
    )
    let remoteProject = Project.fromFolder(
      URL(fileURLWithPath: "/srv/studio-work"),
      serverId: "remote-b"
    )
    let homeClient = FakeSessionServerClient(sessionId: UUID())
    let remoteClient = FakeSessionServerClient(sessionId: UUID())
    let controller = SessionController(
      project: homeProject,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      composerDefaults: ComposerDefaultsStore(store: InMemoryStore()),
      serverClient: homeClient
    )
    controller.composerText = "typed before picking the studio machine"
    controller.wantsNewWorktree = true

    await controller.retarget(to: remoteProject, serverClient: remoteClient)

    // The draft now belongs to the OTHER machine end to end: project,
    // client, and the per-machine defaults scope. The typed prompt and
    // its snapshot's foreign project reference survive untouched.
    #expect(controller.project.id == remoteProject.id)
    #expect(controller.project.serverId == "remote-b")
    #expect(controller.serverClient as? FakeSessionServerClient === remoteClient)
    #expect(
      controller.composerDefaultsScope == .newWorkspace(serverId: "remote-b")
    )
    #expect(controller.composerText == "typed before picking the studio machine")
    let snapshot = controller.draftSnapshot()
    #expect(snapshot.projectServerId == "remote-b")
    #expect(snapshot.projectId == remoteProject.id)
  }

  @Test("A project placeholder cannot send or materialize a chat")
  func placeholderCannotSend() async {
    let controller = SessionController(
      project: .runTargetPlaceholder(serverId: "fresh-vnc"),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    controller.composerText = "keep this draft while I choose a project"
    var didMaterialize = false
    controller.onFirstSend = { _ in didMaterialize = true }

    #expect(!controller.canSend)
    await controller.send()

    #expect(!didMaterialize)
    #expect(controller.composerText == "keep this draft while I choose a project")
    #expect(!controller.hasSentFirst)
  }

  @Test("First send materializes with the submitted text after clearing the composer")
  func firstSendMaterializationReceivesSubmittedText() async {
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/project")),
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    controller.composerText = "  Preserve this title\nwith more detail  "
    var submittedText: String?
    controller.onFirstSend = { submittedText = $0 }

    await controller.send()

    #expect(submittedText == "Preserve this title\nwith more detail")
    // With no configured harness, setup fails and restores the draft.
    #expect(controller.composerText == "Preserve this title\nwith more detail")
  }

  @Test("A deferred durable chat cannot connect before first send")
  func deferredChatDoesNotConnect() async {
    var deferred = session()
    deferred.agentSessionId = ""
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/remote/project"),
      id: deferred.projectId,
      serverId: deferred.serverId
    )
    let controller = SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore()),
      serverClient: FakeSessionServerClient(sessionId: deferred.id)
    )
    controller.configureExistingSession(deferred)

    await controller.connectIfNeeded()

    #expect(controller.model == nil)
    #expect(!controller.isConnecting)
    #expect(controller.connectedAgentSessionId == nil)
  }

  private func controller(for session: ChatSession) -> SessionController {
    let project = Project.fromFolder(
      URL(fileURLWithPath: "/remote/project"),
      id: session.projectId,
      serverId: session.serverId
    )
    let controller = SessionController(
      project: project,
      configCache: ConfigOptionCache(store: InMemoryStore())
    )
    controller.configureExistingSession(session)
    return controller
  }

  private func session() -> ChatSession {
    ChatSession(
      projectId: UUID(),
      serverId: "remote-a",
      harnessId: "codex",
      harnessAccountId: "personal",
      agentSessionId: "agent-1",
      title: "Remote chat",
      worktreeName: nil,
      cwd: "/remote/project",
      configSelections: ["model": "gpt-5.5"],
      createdAt: Date(timeIntervalSince1970: 1)
    )
  }

  private func capability(model: String) -> ServerHarnessCapability {
    ServerHarnessCapability(
      harness: ServerHarness(
        id: "codex",
        name: "Codex",
        symbolName: "chevron.left.forwardslash.chevron.right",
        source: "registry",
        launchKind: "executable",
        enabled: true,
        readiness: ServerHarnessReadiness(state: "ready")
      ),
      modes: nil,
      configOptions: [
        SessionConfigOption(
          id: "model",
          name: "Model",
          category: SessionConfigOption.Category.model,
          currentValue: model,
          options: [SessionConfigSelectOption(value: model, name: model)]
        )
      ],
      supportsGoals: false
    )
  }
}
