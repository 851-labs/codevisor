import Foundation
import Observation
import ACPKit

@MainActor
@Observable
final public class SessionController {
  public enum Status: Equatable, Sendable {
    case idle
    case connecting(String)
    case failed(String)
  }

  public enum PreparationState: Equatable {
    case loading
    case ready
    case failed
  }

  public enum ConfigurationValidationState: Equatable {
    case ready
    case connecting
    case failed(String)
  }

  public private(set) var transcriptProjectionRevision: UInt64 = 0
  public var transcriptPresentationFrameRevision: UInt64 { presentationClock.revision }
  @ObservationIgnored let transcriptProjectionID = UUID()
  @ObservationIgnored public private(set) lazy var presentationClock = TranscriptPresentationClock(
    present: { [weak self] in self?.model?.flushPendingEvents() },
    preferPending: { [weak self] in self?.model?.preferPresentationFrameIfPending() },
    onAppear: { [weak self] in self?.model?.viewDidAppear() },
    onDisappear: { [weak self] in self?.model?.viewDidDisappear() }
  )

  public var composerText: String = "" { didSet { draftDidChange() } }
  public var composerAttachments: [ComposerAttachment] { attachments.items }
  @ObservationIgnored public private(set) lazy var attachments = ComposerAttachments(
    files: attachmentFiles,
    client: { [weak self] in self?.serverClient },
    uploadLimitBytes: { [weak self] in
      guard let self else { return MachineStatus.legacyUploadLimitBytes }
      return self.machines?.statusByMachineId[self.project.serverId]?.uploadLimitBytes
        ?? MachineStatus.legacyUploadLimitBytes
    },
    onChange: { [weak self] in self?.draftDidChange() },
    reportFailure: { [weak self] message in self?.status = .failed(message) },
    rememberPreview: { [weak self] preview, fileId in
      self?.sentAttachmentPreviews.remember(preview, for: fileId)
    }
  )
  @ObservationIgnored var sentAttachmentPreviews = SentAttachmentPreviews()
  @ObservationIgnored lazy var sends = SendQueue(
    attachments: attachments,
    readiness: { [weak self] in self?.sendReadiness ?? .failed(Self.closedChatReason) },
    connect: { [weak self] message in await self?.connectForSend(message) ?? .failed(Self.closedChatReason) },
    deliver: { [weak self] message, route, model in await self?.deliverSend(message, route: route, to: model) },
    onUploaded: { [weak self] uploaded, sentFileID in self?.rememberUploaded(uploaded, sentAs: sentFileID) },
    onChange: { [weak self] in self?.transcriptProjectionRevision &+= 1 }
  )
  public let attachmentFiles: ComposerAttachmentFileStore
  public internal(set) var harnesses: [ServerHarness] = []
  public internal(set) var preparationState: PreparationState = .loading
  public internal(set) var isRefreshingHarnessCapabilities = false
  public internal(set) var configurationValidationState: ConfigurationValidationState = .ready
  public internal(set) var configurationAdjustmentMessage: String?
  public internal(set) var isLoadingInitialHistory = false {
    didSet {
      if isLoadingInitialHistory != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  var initialHistoryLoadStartedAt: TimeInterval?
  public var selectedHarnessId: String? { didSet { draftDidChange() } }
  @ObservationIgnored public var promptClientId: String? {
    didSet { model?.promptClientId = promptClientId }
  }
  public internal(set) var model: SessionModel? {
    didSet {
      model?.promptClientId = promptClientId
      if model !== oldValue { transcriptProjectionRevision &+= 1 }
      if model !== oldValue {
        oldValue?.presentationFrameRequester = nil
        oldValue?.reschedulePendingEventsForCurrentVisibility()
      }
      guard let model, model !== oldValue else { return }
      model.presentationFrameRequester = { [weak self] in
        self?.presentationClock.requestFrame() == true
      }
      for _ in 0..<presentationClock.visibleViewCount { model.viewDidAppear() }
    }
  }
  public internal(set) var status: Status = .idle {
    didSet {
      if status != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var serverWaitMessage: String? {
    didSet {
      if serverWaitMessage != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var pendingSendStartedAt: Date?
  public internal(set) var presentsBotConversation = false {
    didSet {
      if presentsBotConversation != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  @ObservationIgnored public var scrollState: SessionScrollState? {
    didSet { onScrollStateChange?(scrollState) }
  }
  @ObservationIgnored public var onScrollStateChange: ((SessionScrollState?) -> Void)?
  public var isTodosExpanded = false {
    didSet { onTodosExpandedChange?(isTodosExpanded) }
  }
  @ObservationIgnored public var onTodosExpandedChange: ((Bool) -> Void)?
  @ObservationIgnored public let disclosure = TranscriptDisclosureStore()
  public internal(set) var userSendSignal = 0
  public internal(set) var userSendAnimationRequest: UserSendAnimationRequest?
  @ObservationIgnored var userSendAnimationCoordinator = UserSendAnimationCoordinator()

  public var project: Project {
    didSet {
      draftDidChange()
      refreshSandboxPrewarm()
    }
  }
  public var onFirstSend: ((String) -> Void)?
  public var onScratchProjectCreated: ((Project) -> Void)?
  public var projectClone: ProjectCloneRequest?
  public internal(set) var projectCloneFailure: ProjectMachineSetup.Failure?
  public var onProjectCloned: ((Project) -> Void)?
  public var onSetupFailed: (() -> Void)?
  @ObservationIgnored public var sendInterceptor: ((ServerPromptDelivery) -> Bool)?
  public internal(set) var submitRequest = 0
  public var resumeAgentSessionId: String?
  public var serverSession: ChatSession?
  public var wantsNewWorktree = false {
    didSet {
      if wantsNewWorktree, sandboxTarget != nil { wantsNewWorktree = false }
      if !wantsNewWorktree {
        sessionCwdOverride = nil
        worktreeName = nil
      }
      draftDidChange()
    }
  }
  public internal(set) var worktreeName: String?
  public internal(set) var sessionCwdOverride: String?
  public var onWorktreeCreated: ((ServerWorktree) -> Void)?
  public var sandboxTarget: SandboxTarget? {
    didSet {
      if sandboxTarget != nil { wantsNewWorktree = false }
      refreshSandboxPrewarm()
    }
  }
  @ObservationIgnored var sandboxPrewarm: SandboxPrewarm?
  public var onSandboxReady: ((ChatSession, ChatSession, Project) -> Void)?
  public internal(set) var setupPhases: [SessionSetupPhase] = [] {
    didSet {
      if setupPhases != oldValue { transcriptProjectionRevision &+= 1 }
    }
  }
  public internal(set) var showsNewChatAfterSetupFailure = false
  public var shouldShowNewChatComposer: Bool {
    showsNewChatAfterSetupFailure || (!hasSentFirst && onFirstSend != nil)
  }
  public var hasAcceptedFirstSend: Bool { hasSentFirst }
  public internal(set) var isSubmitting = false
  public internal(set) var isResolvingQuestion = false
  @ObservationIgnored var questionDrafts: [String: QuestionDraft] = [:]
  public internal(set) var transcriptQuestionRevealSignal = 0
  public var isTypingTranscriptAnswer = false
  public var presentedSetupRequest: TranscriptSetupRequest?
  public var onAgentSessionCreated: ((String) -> Void)?
  public var onTurnEnded: (() -> Void)?
  public internal(set) var liveTurnEndRevision: UInt64 = 0
  public internal(set) var connectedAgentSessionId: String?

  let configCache: ConfigOptionCache
  let composerDefaults: ComposerDefaultsStore?
  public var hostWorkspaceId: UUID?
  var serverClient: (any CodevisorServerClienting)?
  @ObservationIgnored weak var machines: MachineController?
  let notificationDelivery: (any ChatNotificationDelivering)?
  var hasSentFirst = false
  var connectedHarnessId: String?
  @ObservationIgnored private(set) lazy var pendingConfiguration = PendingSessionConfiguration(
    currentHarness: { [weak self] in self?.connectedHarnessId ?? self?.selectedHarnessId },
    fallbackOptions: { [weak self] in self?.configOptions ?? [] },
    onChange: { [weak self] in self?.draftDidChange() }
  )
  @ObservationIgnored var automaticSelectionIntent: ComposerSelectionIntent?
  @ObservationIgnored var automaticSelectionNeedsResolution = false
  @ObservationIgnored public var onDraftChange: ((ComposerDraftStore.Draft) -> Void)?
  @ObservationIgnored var isRestoringDraft = false
  var pendingNewChatAnalytics = false
  @ObservationIgnored let connectionAttempt = SessionConnectionAttempt()
  @ObservationIgnored var isFirstSendConnecting = false
  var analyticsUsageBaseline: SessionUsage?
  var pendingPlanModeOn: Bool?
  var modeStateByHarness: [String: SessionModeState] = [:]
  var configOptionsByHarness: [String: [SessionConfigOption]] = [:]
  var supportsGoalsByHarness: [String: Bool] = [:]
  var supportsSteeringByHarness: [String: Bool] = [:]
  var queuedPromptEdit: QueuedPromptEdit?
  var harnessCapabilityRequestRevision: UInt64 = 0
  var retargetRevision: UInt64 = 0
  public internal(set) var isResolvingModelConfiguration = false
  var modelConfigurationResolutionRevision: UInt64 = 0
  public internal(set) var pendingModelPick: PendingModelPick?
  @ObservationIgnored var modelPickRevision: UInt64 = 0
  @ObservationIgnored var stagedModelNames: [String: String] = [:]
  public internal(set) var draftModelAvailability: DraftModelAvailability?
  var draftModelSettings: [String: [SessionConfigOption]] = [:]
  public internal(set) var resolvingDraftModelSettingsKey: String?
  var acknowledgedUnavailableModelValue: String?
  var dismissedUnavailableModelNotice: String?
  var firstSendSelections: [String: String] = [:]
  var didLoadExistingHarnessCapabilities = false
  var didFinishExistingRuntimeConfiguration = false
  var didLoadExistingRuntimeConfiguration = false
  var existingConfigurationError: String?

  public var isGoalComposerArmed = false { didSet { draftDidChange() } }

  public var isGoalEditing = false { didSet { draftDidChange() } }

  var composerTextBeforeGoalEdit: String? { didSet { draftDidChange() } }

  var pendingGoal: String?

  public internal(set) var pendingPlanApproval = false

  public var transcriptCache: TranscriptPageCache?
  var cachedTranscriptModel: SessionModel?
  var transcriptCacheLoadGeneration: UInt64 = 0

  public init(
    project: Project,
    configCache: ConfigOptionCache,
    composerDefaults: ComposerDefaultsStore? = nil,
    hostWorkspaceId: UUID? = nil,
    serverClient: (any CodevisorServerClienting)? = nil,
    machines: MachineController? = nil,
    notificationDelivery: (any ChatNotificationDelivering)? = nil,
    attachmentFiles: ComposerAttachmentFileStore = .temporary()
  ) {
    self.project = project
    self.attachmentFiles = attachmentFiles
    self.configCache = configCache
    self.composerDefaults = composerDefaults
    self.hostWorkspaceId = hostWorkspaceId
    self.serverClient = serverClient
    self.machines = machines
    self.notificationDelivery = notificationDelivery
    if seedFromCachedServerCapabilities() {
      preparationState = .ready
    }
  }

  func resolveRetargetedComposerSelection(
    _ intent: ComposerSelectionIntent,
    targetServerId: String
  ) async {
    guard isStillTargeting(intent, onServer: targetServerId),
      selectedHarnessId == intent.harnessId,
      let client = serverClient
    else {
      clearUnreachableAutomaticSelection(intent, targetServerId: targetServerId)
      return
    }
    guard let modelValue = intent.modelValue else {
      automaticSelectionNeedsResolution = false
      return
    }
    guard
      let currentModel = intent.catalogModel(
        offering: modelValue,
        in: configOptionsByHarness[intent.harnessId]
      )
    else {
      rejectRetargetedComposerSelection(intent, modelValue: modelValue)
      return
    }

    let revision = beginModelConfigurationResolution()
    defer { finishModelConfigurationResolution(revision) }

    let destinationValues = rememberedConfigSelections(forHarness: intent.harnessId)
    let requested = intent.requestedSelections(
      modelOptionId: currentModel.id,
      modelValue: modelValue,
      over: destinationValues
    )
    guard
      let response = try? await client.capabilities(
        cwd: capabilityCwd,
        harnessId: intent.harnessId,
        configSelections: requested
      )
    else { return }

    guard modelConfigurationResolutionRevision == revision,
      isStillTargeting(intent, onServer: targetServerId),
      let capability = intent.resolvedCapability(in: response),
      let resolvedModel = Self.modelOption(in: capability.configOptions)
    else { return }
    guard ComposerSelectionIntent.modelWasApplied(resolvedModel, in: capability) else {
      rejectRetargetedComposerSelection(intent, modelValue: modelValue)
      return
    }

    adoptResolvedComposerSelection(
      intent,
      options: capability.configOptions,
      resolvedModel: resolvedModel,
      destinationValues: destinationValues
    )
  }

  private func beginModelConfigurationResolution() -> UInt64 {
    modelConfigurationResolutionRevision &+= 1
    let revision = modelConfigurationResolutionRevision
    isResolvingModelConfiguration = true
    return revision
  }

  private func finishModelConfigurationResolution(_ revision: UInt64) {
    guard modelConfigurationResolutionRevision == revision else { return }
    isResolvingModelConfiguration = false
  }

  func cancelModelConfigurationResolution() {
    modelConfigurationResolutionRevision &+= 1
    isResolvingModelConfiguration = false
  }

  private func isStillTargeting(_ intent: ComposerSelectionIntent, onServer serverId: String) -> Bool {
    project.serverId == serverId && automaticSelectionIntent == intent
  }

  private func clearUnreachableAutomaticSelection(
    _ intent: ComposerSelectionIntent,
    targetServerId: String
  ) {
    guard project.serverId == targetServerId, !harnesses.isEmpty,
      automaticSelectionIntent == intent
    else { return }
    clearAutomaticSelection()
  }

  private func rememberedConfigSelections(forHarness harnessId: String) -> [String: String] {
    composerDefaults?.configSelections(forHarness: harnessId, in: resolvedComposerDefaultsScope) ?? [:]
  }

  private func adoptResolvedComposerSelection(
    _ intent: ComposerSelectionIntent,
    options: [SessionConfigOption],
    resolvedModel: SessionConfigOption,
    destinationValues: [String: String]
  ) {
    var options = options
    let resolvedValues = intent.resolveRememberedOptions(
      in: &options,
      resolvedModel: resolvedModel,
      resolvedModelValue: resolvedModel.currentValue,
      destinationValues: destinationValues
    )
    configOptionsByHarness[intent.harnessId] = options
    pendingConfiguration.replaceValues(resolvedValues, for: intent.harnessId)
    automaticSelectionIntent = ComposerSelectionIntent(
      harnessId: intent.harnessId,
      configValues: resolvedValues,
      modelValue: resolvedModel.currentValue,
      modelName: resolvedModel.currentName
    )
    automaticSelectionNeedsResolution = false
  }

  private func rejectRetargetedComposerSelection(_ intent: ComposerSelectionIntent, modelValue: String) {
    clearAutomaticSelection()
    markDraftModel(
      modelValue,
      name: intent.modelName ?? modelValue,
      harnessId: intent.harnessId,
      checking: false
    )
  }
}

public struct PendingModelPick: Equatable, Sendable {
  public let harnessId: String
  public let value: String
  public let name: String
}

public enum DraftModelAvailability: Equatable, Sendable {
  case checking(harnessId: String, value: String, name: String)
  case unavailable(harnessId: String, value: String, name: String)

  var harnessId: String {
    switch self {
    case let .checking(harnessId, _, _), let .unavailable(harnessId, _, _): harnessId
    }
  }

  var value: String {
    switch self {
    case let .checking(_, value, _), let .unavailable(_, value, _): value
    }
  }

  var name: String {
    switch self {
    case let .checking(_, _, name), let .unavailable(_, _, name): name
    }
  }
}

public enum SessionControllerError: Error {
  case serverUnavailable
  case fileNotCapturedYet
}

#if DEBUG
  extension SessionController {
    static public func preview(
      project: Project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd")),
      model: SessionModel? = nil,
      harnesses: [ServerHarness] = SessionController.previewHarnesses
    ) -> SessionController {
      let controller = SessionController(
        project: project,
        configCache: ConfigOptionCache(store: InMemoryStore())
      )
      controller.harnesses = harnesses
      controller.preparationState = .ready
      controller.selectedHarnessId = harnesses.first?.id
      controller.model = model
      for harness in harnesses {
        controller.supportsGoalsByHarness[harness.id] = true
        controller.supportsSteeringByHarness[harness.id] = true
        controller.modeStateByHarness[harness.id] = SessionModeState(
          currentModeId: "default",
          availableModes: [
            SessionMode(id: "default", name: "Default", canonicalId: "fullAccess"),
            SessionMode(id: "plan", name: "Plan", canonicalId: "plan"),
          ]
        )
      }
      return controller
    }

    nonisolated static public var previewHarnesses: [ServerHarness] {
      [
        ServerHarness(
          id: "claude-code", name: "Claude Code", symbolName: "sparkle", source: "registry",
          launchKind: "executable", enabled: true,
          readiness: ServerHarnessReadiness(state: "ready")
        ),
        ServerHarness(
          id: "codex", name: "Codex", symbolName: "chevron.left.forwardslash.chevron.right",
          source: "registry", launchKind: "executable", enabled: true,
          readiness: ServerHarnessReadiness(state: "ready")
        ),
      ]
    }
  }
#endif
