import Foundation
import ACPKit

extension SessionController {
  /// Adopts server changes that affect this controller's runtime while
  /// ignoring presentation-only metadata (title, attention, unread state,
  /// and timestamps). Session list events replace the complete
  /// `ChatSession`, so comparing the whole value would re-publish this
  /// observed property for every remote attention update.
  @discardableResult
  public func reconcileExistingSession(_ session: ChatSession) -> Bool {
    guard serverSession.map(ExistingSessionRuntimeState.init) != ExistingSessionRuntimeState(session)
    else { return false }
    configureExistingSession(session)
    return true
  }

  /// Binds a persisted chat to this controller and paints its last accepted
  /// selections over cached option definitions. The values remain
  /// provisional until the live session reconnect validates them.
  public func configureExistingSession(_ session: ChatSession) {
    let identityChanged =
      serverSession?.id != session.id
      || resumeAgentSessionId != session.agentSessionId
    serverSession = session
    resumeAgentSessionId = session.agentSessionId
    // New Chat defaults stop applying once this is a real chat: a draft's
    // pending "is the remembered model still offered?" check (and its
    // notice) belongs to the draft, not to the chat's own model.
    if session.agentSessionId?.isEmpty == false {
      draftModelAvailability = nil
    }
    if !session.harnessId.isEmpty {
      selectedHarnessId = session.harnessId
    }
    guard model == nil else { return }
    // An in-flight connect owns the validation state machine: a refresh
    // snapshot arriving mid-connect usually carries the agent session id
    // that this very connect just minted server-side (`session.updated`
    // from `ensureAgentSessionFor`). Resetting to `.connecting` here would
    // wedge the composer forever — nothing on the send path recomputes the
    // state after the model is published. The id itself was still adopted
    // above; the connect settles the flags when it completes.
    guard identityChanged, session.agentSessionId?.isEmpty == false, !isConnecting else { return }
    didLoadExistingHarnessCapabilities = false
    didFinishExistingRuntimeConfiguration = false
    didLoadExistingRuntimeConfiguration = false
    existingConfigurationError = nil
    configurationAdjustmentMessage = nil
    configurationValidationState = .connecting
    isLoadingInitialHistory = true
    initialHistoryLoadStartedAt = ProcessInfo.processInfo.systemUptime
  }

  private static func provisionalConfigOption(id: String, value: String) -> SessionConfigOption {
    let normalized = id.lowercased()
    let category: String? =
      if normalized == "model" {
        SessionConfigOption.Category.model
      } else if normalized.contains("reason")
        || normalized.contains("effort")
        || normalized.contains("thinking")
      {
        SessionConfigOption.Category.thoughtLevel
      } else if normalized.contains("speed") {
        SessionConfigOption.Category.speed
      } else {
        SessionConfigOption.Category.modelConfig
      }
    return SessionConfigOption(
      id: id,
      name: id.replacingOccurrences(of: "_", with: " ").capitalized,
      category: category,
      currentValue: value,
      options: [SessionConfigSelectOption(value: value, name: value)]
    )
  }

  var hasExistingAgentSession: Bool {
    resumeAgentSessionId?.isEmpty == false
      || serverSession?.agentSessionId?.isEmpty == false
  }

  public var isConnectingToHarness: Bool {
    configurationValidationState == .connecting
  }

  public var configurationValidationError: String? {
    guard case let .failed(message) = configurationValidationState else { return nil }
    return message
  }

  func updateConfigurationValidationState() {
    guard hasExistingAgentSession else {
      configurationValidationState = .ready
      return
    }
    if didLoadExistingRuntimeConfiguration
      || (didFinishExistingRuntimeConfiguration && didLoadExistingHarnessCapabilities)
    {
      configurationValidationState = .ready
    } else if didFinishExistingRuntimeConfiguration,
      let existingConfigurationError
    {
      configurationValidationState = .failed(existingConfigurationError)
    } else {
      configurationValidationState = .connecting
    }
  }

  /// Selectable config options. A draft shows its machine's catalog with
  /// its own picks (and remembered New Chat defaults) applied. An existing
  /// chat shows only its own values: the runtime's reported options, or the
  /// chat's saved selections over the catalog's option lists. Catalog and
  /// inspection `currentValue`s never stand in for an existing chat's own.
  public var configOptions: [SessionConfigOption] {
    acceptsNewChatDefaults ? draftConfigOptions : existingChatConfigOptions
  }

  private var draftConfigOptions: [SessionConfigOption] {
    guard let harnessId = activeHarnessId else { return [] }
    let pendingConfig = pendingConfigByHarness[harnessId] ?? [:]
    // Onboarding first seeds the controller with a harness-only catalog,
    // then warms the shared cache with model metadata in the background.
    // Do not let that provisional empty controller snapshot hide the
    // cache's newer usable options while the project-specific refresh is
    // still in flight.
    let cachedOptions = configCache.options(forHarness: harnessId, onServer: project.serverId)
    var options =
      configOptionsByHarness[harnessId].flatMap {
        $0.isEmpty && !cachedOptions.isEmpty ? nil : $0
      } ?? cachedOptions
    // A staged model the catalog does not describe uses its own inspected
    // settings once known (see `resolveDraftModelSettingsIfNeeded`).
    if let catalogModel = Self.modelOption(in: options),
      let staged = pendingConfig[catalogModel.id], !staged.isEmpty,
      let resolved = draftModelSettings[
        Self.draftModelSettingsKey(harnessId: harnessId, model: staged)]
    {
      options = resolved
    }
    // A draft's model is only ever the user's own: a pick, a remembered
    // New Chat default, or a carried selection — all staged in
    // `pendingConfig`. The catalog's current value is the harness's own
    // default (or a missing model's stand-in), never a choice the user
    // made, so without a staged model the chip asks for a pick.
    if let index = options.firstIndex(where: Self.isModelOption),
      pendingConfig[options[index].id]?.isEmpty != false
    {
      options[index].currentValue = ""
    }
    return applying(pendingConfig, to: options)
  }

  private var existingChatConfigOptions: [SessionConfigOption] {
    guard let harnessId = activeHarnessId else { return [] }
    let pending = pendingConfigByHarness[harnessId] ?? [:]
    var options: [SessionConfigOption]
    if let model, !model.configOptions.isEmpty {
      options = model.configOptions
    } else {
      // A connected runtime with NO options is not an answer to trust:
      // Claude reports none whenever its model list loses the startup
      // race, and publishes the list later as a config update. Until
      // then the catalog supplies option LISTS only; values are the
      // chat's own, and an option whose value is unknown stays hidden
      // (the model option stays, empty, so the chip can wait for it).
      let saved = existingChatSelections
      let definitions =
        configOptionsByHarness[harnessId].flatMap { $0.isEmpty ? nil : $0 }
        ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
      options = definitions.compactMap { definition in
        var option = definition
        if let value = saved[option.id] {
          option.currentValue = value
        } else if Self.isModelOption(option) {
          option.currentValue = ""
        } else {
          return nil
        }
        return option
      }
      for (configId, value) in saved.sorted(by: { $0.key < $1.key })
      where !options.contains(where: { $0.id == configId }) {
        // The value snapshot is enough to paint a provisional picker
        // even when this machine has no cached definitions yet.
        options.append(Self.provisionalConfigOption(id: configId, value: value))
      }
      // Keep a saved value visible (by its raw id) when stale catalog
      // lists do not carry it; the runtime decides its availability.
      for index in options.indices {
        let value = options[index].currentValue
        if !value.isEmpty, !options[index].options.contains(where: { $0.value == value }) {
          options[index].options.append(SessionConfigSelectOption(value: value, name: value))
        }
      }
    }
    if unavailableExistingModelValue != nil,
      let index = options.firstIndex(where: Self.isModelOption)
    {
      options[index].currentValue = ""
    }
    return applying(pending, to: options)
  }

  /// The chat's own saved values: the server's record, falling back to the
  /// selection captured when this device sent the chat's first prompt.
  var existingChatSelections: [String: String] {
    var values = firstSendSelections
    values.merge(serverSession?.configSelections ?? [:]) { _, saved in saved }
    return values.filter { !$0.value.isEmpty }
  }

  /// Overlays staged picks. A staged model the list does not carry keeps
  /// its display name so the chip never rolls back to another model.
  private func applying(
    _ pending: [String: String],
    to options: [SessionConfigOption]
  ) -> [SessionConfigOption] {
    guard !pending.isEmpty else { return options }
    return options.map { option in
      guard let value = pending[option.id] else { return option }
      var updated = option
      updated.currentValue = value
      if !value.isEmpty, Self.isModelOption(option),
        !option.options.contains(where: { $0.value == value }),
        let name = stagedModelNames[value]
      {
        updated.options.append(SessionConfigSelectOption(value: value, name: name))
      }
      return updated
    }
  }

  static func isModelOption(_ option: SessionConfigOption) -> Bool {
    option.category == SessionConfigOption.Category.model || option.id == "model"
  }

  /// The model option id for a harness, from whichever definitions exist,
  /// without consulting `configOptions` (which depends on this).
  func modelConfigId(forHarness harnessId: String) -> String {
    let sources: [[SessionConfigOption]] = [
      model?.configOptions ?? [],
      configOptionsByHarness[harnessId] ?? [],
      configCache.options(forHarness: harnessId, onServer: project.serverId),
    ]
    for options in sources {
      if let option = options.first(where: {
        $0.category == SessionConfigOption.Category.model
      }) {
        return option.id
      }
    }
    return "model"
  }

  /// Categories folded into the combined model dropdown rather than shown
  /// as individual picker chips.
  private static let modelMenuCategories: Set<String> = [
    SessionConfigOption.Category.model,
    SessionConfigOption.Category.thoughtLevel,
    SessionConfigOption.Category.speed,
  ]

  /// Config categories that follow the user between composers. Modes remain
  /// local to a chat; run location is remembered separately from harness
  /// configuration.
  static let rememberedConfigCategories: Set<String> = [
    SessionConfigOption.Category.model,
    SessionConfigOption.Category.thoughtLevel,
    SessionConfigOption.Category.speed,
    SessionConfigOption.Category.modelConfig,
  ]

  /// The model choice shown in the combined model dropdown.
  public var modelOption: SessionConfigOption? {
    configOptions.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
  }

  /// Thinking/reasoning controls shown in the combined model dropdown.
  /// Some agents expose more than one (for example, Thinking plus Effort).
  public var thoughtLevelOptions: [SessionConfigOption] {
    configOptions.filter { $0.category == SessionConfigOption.Category.thoughtLevel && !$0.options.isEmpty }
  }

  /// The speed (standard/fast) shown in the combined model dropdown; only
  /// present when the agent/model pair supports a fast tier.
  public var speedOption: SessionConfigOption? {
    configOptions.first { $0.category == SessionConfigOption.Category.speed && !$0.options.isEmpty }
  }

  public var hasModelMenu: Bool {
    modelOption != nil || !thoughtLevelOptions.isEmpty || speedOption != nil
  }

  /// True while the model list — or, for an existing chat, the chat's own
  /// model — is not known yet. The composer reserves the model chip's place
  /// with a single spinner during that gap instead of popping it in later
  /// or painting a value that is not the chat's.
  public var isLoadingModelMenu: Bool {
    if !acceptsNewChatDefaults {
      return isAwaitingExistingChatModel
    }
    guard !hasModelMenu else { return false }
    // A background revalidation is stale-while-revalidate like every
    // other catalog consumer: only spin when there is NO settled answer
    // at all. A draft whose machine has nothing usable but a known
    // sign-in-required list holds its "Select a harness" chip steady
    // instead of flickering on every sync-driven refresh.
    if isRefreshingHarnessCapabilities { return !hasSettledCatalogKnowledge }
    if isConnecting || isConnectingToHarness { return true }
    // A draft with no spawned agent yet (new-chat page, deferred chats)
    // fetching harness capabilities: hold the model chip's slot with a
    // spinner too, instead of rendering nothing until options land.
    return model == nil && preparationState == .loading
  }

  /// An existing chat whose own model value has not been reported yet.
  private var isAwaitingExistingChatModel: Bool {
    if unavailableExistingModelValue != nil { return false }
    if let option = modelOption, !option.currentValue.isEmpty { return false }
    if case .failed = status { return false }
    if case .failed = configurationValidationState { return false }
    if isConnectingToHarness { return true }
    // Once the runtime connection settled, an empty value is a real
    // "nothing selected", not a pending answer.
    return model == nil && (hasExistingAgentSession || hasSentFirst || isConnecting)
  }

  /// The config options still shown as individual picker chips (model
  /// config, unknown categories), in a sensible order. Mode options are
  /// excluded entirely: the composer's plan toggle is the only mode control
  /// (everything else runs in the harness's full-access/build default).
  public var pickerOptions: [SessionConfigOption] {
    let order = [SessionConfigOption.Category.modelConfig]
    return
      configOptions
      .filter { option in
        !option.options.isEmpty
          && !Self.modelMenuCategories.contains(option.category ?? "")
          && option.category != SessionConfigOption.Category.mode
          && option.id != "mode"
      }
      .sorted { left, right in
        let leftIndex = order.firstIndex(of: left.category ?? "") ?? 99
        let rightIndex = order.firstIndex(of: right.category ?? "") ?? 99
        if leftIndex == rightIndex { return left.name < right.name }
        return leftIndex < rightIndex
      }
  }

  /// Applies a picker change. A draft stages it and records it as the
  /// machine's New Chat default; an existing chat applies it to its own
  /// runtime (or stages it until the runtime connects) and never touches
  /// New Chat defaults or the shared catalog cache.
  @discardableResult
  public func setConfigOption(_ configId: String, _ value: String) async -> Bool {
    clearAutomaticSelection()
    let optionBeforeChange = configOptions.first { $0.id == configId }
    let previousValue = optionBeforeChange?.currentValue
    let isModelChange =
      optionBeforeChange.map(Self.isModelOption) ?? (configId == "model")
    let wasDraft = acceptsNewChatDefaults
    let harnessId = activeHarnessId
    var accepted = true
    if let model, !isConnectingToHarness, let harnessId {
      // Keep the pick visible while it is in flight, even when the
      // runtime has not reported this option yet.
      pendingConfigByHarness[harnessId, default: [:]][configId] = value
      accepted = await model.setConfigOption(configId: configId, value: value)
      if pendingConfigByHarness[harnessId]?[configId] == value {
        pendingConfigByHarness[harnessId]?[configId] = nil
      }
      if let connectedHarnessId, !model.configOptions.isEmpty {
        configOptionsByHarness[connectedHarnessId] = model.configOptions
      }
    } else if let harnessId = wasDraft ? selectedHarnessId : harnessId {
      // Not connected yet (or the runtime is still connecting): stage it
      // and apply it before submitting work. No temporary harness
      // inspection here: that launched a CLI process per pick and,
      // whenever the process could not honor the request, it silently
      // replaced the choice with the harness default. First send
      // validates against the real runtime instead.
      pendingConfigByHarness[harnessId, default: [:]][configId] = value
    }
    if accepted, isModelChange {
      if previousValue != value {
        captureModelSelected(modelId: value, previousModelId: previousValue)
      }
      configurationAdjustmentMessage = nil
      draftModelAvailability = nil
      acknowledgedUnavailableModelValue =
        serverSession?.unavailableConfigSelections?[configId] ?? acknowledgedUnavailableModelValue
      // The user just chose a model, so a "we swapped your model" notice
      // no longer describes the current state.
      model?.clearModelFallback()
    }
    // Explicit picker actions in an unsent composer become the machine's
    // New Chat defaults immediately. Existing chats never write them.
    if accepted, wasDraft, acceptsNewChatDefaults,
      Self.rememberedConfigCategories.contains(optionBeforeChange?.category ?? "")
        || isModelChange,
      let harnessId = selectedHarnessId
    {
      // Persist the visible selection so model-dependent values the user
      // accepted alongside this pick are remembered too.
      composerDefaults?.rememberConfigSelections(
        in: resolvedComposerDefaultsScope,
        harnessId: harnessId,
        configValues: rememberedConfigValues.merging([configId: value]) { _, picked in picked }
      )
      composerDefaults?.rememberHarnessSelection(
        in: resolvedComposerDefaultsScope,
        harnessId: harnessId
      )
    }
    return accepted
  }

  public func dismissConfigurationAdjustment() {
    configurationAdjustmentMessage = nil
  }

  /// Validates an automatically carried machine-switch selection against a
  /// temporary destination inspection. The model is resolved first by the
  /// server; each dependent setting then prefers the outgoing value, the
  /// destination machine's remembered value, and finally the harness default.
  /// Automatic carry remains draft-local until an explicit picker action or
  /// first send records it as this machine's new default.
  func resolveRetargetedComposerSelection(
    _ intent: ComposerSelectionIntent,
    targetServerId: String
  ) async {
    guard project.serverId == targetServerId,
      automaticSelectionIntent == intent,
      selectedHarnessId == intent.harnessId,
      let client = serverClient
    else {
      if project.serverId == targetServerId, !harnesses.isEmpty,
        automaticSelectionIntent == intent
      {
        clearAutomaticSelection()
      }
      return
    }
    guard let modelValue = intent.modelValue else {
      automaticSelectionNeedsResolution = false
      return
    }
    guard let currentOptions = configOptionsByHarness[intent.harnessId],
      let currentModel = Self.modelOption(in: currentOptions),
      currentModel.options.contains(where: { $0.value == modelValue })
    else {
      // The carried pick stays the draft's choice; a destination that
      // does not offer it asks for another model.
      clearAutomaticSelection()
      markDraftModel(
        modelValue,
        name: intent.modelName ?? modelValue,
        harnessId: intent.harnessId,
        checking: false
      )
      return
    }

    modelConfigurationResolutionRevision &+= 1
    let revision = modelConfigurationResolutionRevision
    isResolvingModelConfiguration = true
    defer {
      if modelConfigurationResolutionRevision == revision {
        isResolvingModelConfiguration = false
      }
    }

    let destinationValues =
      composerDefaults?.configSelections(
        forHarness: intent.harnessId,
        in: resolvedComposerDefaultsScope
      ) ?? [:]
    var requested = destinationValues
    requested.merge(intent.configValues) { _, carried in carried }
    requested[currentModel.id] = modelValue

    do {
      let response = try await client.capabilities(
        cwd: capabilityCwd,
        harnessId: intent.harnessId,
        configSelections: requested
      )
      guard modelConfigurationResolutionRevision == revision,
        project.serverId == targetServerId,
        automaticSelectionIntent == intent,
        let capability = response.harnesses.first(where: {
          $0.harness.id == intent.harnessId
        }),
        !capability.configOptions.isEmpty
      else { return }

      guard let resolvedModel = Self.modelOption(in: capability.configOptions) else { return }
      let resolvedModelValue = resolvedModel.currentValue
      let modelWasApplied =
        capability.unappliedConfigSelections?[resolvedModel.id] == nil
        && resolvedModel.options.contains { $0.value == resolvedModelValue }
      guard modelWasApplied else {
        clearAutomaticSelection()
        markDraftModel(
          modelValue,
          name: intent.modelName ?? modelValue,
          harnessId: intent.harnessId,
          checking: false
        )
        return
      }

      var options = capability.configOptions
      var resolvedValues: [String: String] = [:]
      for index in options.indices
      where Self.rememberedConfigCategories.contains(options[index].category ?? "") {
        let option = options[index]
        // A server-reconciled model id (renamed upstream) replaces the
        // carried one.
        let carriedValue =
          option.id == resolvedModel.id ? resolvedModelValue : intent.configValues[option.id]
        let acceptedCarriedValue =
          option.currentValue == carriedValue ? carriedValue : nil
        let value = [acceptedCarriedValue, destinationValues[option.id], option.currentValue]
          .compactMap { $0 }
          .first { candidate in
            option.options.contains { $0.value == candidate }
          }
        guard let value else { continue }
        options[index].currentValue = value
        resolvedValues[option.id] = value
      }
      configOptionsByHarness[intent.harnessId] = options
      pendingConfigByHarness[intent.harnessId] = resolvedValues
      automaticSelectionIntent = ComposerSelectionIntent(
        harnessId: intent.harnessId,
        configValues: resolvedValues,
        modelValue: resolvedModelValue,
        modelName: resolvedModel.currentName
      )
      automaticSelectionNeedsResolution = false
    } catch {
      // Keep the optimistic carried values queued. A live catalog refresh
      // or first connection remains the final validator when this
      // best-effort inspection is unavailable.
    }
  }

  func resolveAutomaticSelectionIfNeeded() async {
    guard automaticSelectionNeedsResolution, let intent = automaticSelectionIntent else {
      return
    }
    await resolveRetargetedComposerSelection(intent, targetServerId: project.serverId)
  }
}

/// The subset of a server session consumed by `SessionController`. Sidebar
/// and attention metadata is rendered from `ProjectListModel`, not from the
/// controller's retained session snapshot.
private struct ExistingSessionRuntimeState: Equatable {
  let id: UUID
  let projectId: UUID
  let serverId: String
  let harnessId: String
  let harnessAccountId: String?
  let agentSessionId: String?
  let worktreeName: String?
  let cwd: String?
  let configSelections: [String: String]?
  let unavailableConfigSelections: [String: String]?

  init(_ session: ChatSession) {
    id = session.id
    projectId = session.projectId
    serverId = session.serverId
    harnessId = session.harnessId
    harnessAccountId = session.harnessAccountId
    agentSessionId = session.agentSessionId
    worktreeName = session.worktreeName
    cwd = session.cwd
    configSelections = session.configSelections
    unavailableConfigSelections = session.unavailableConfigSelections
  }
}
