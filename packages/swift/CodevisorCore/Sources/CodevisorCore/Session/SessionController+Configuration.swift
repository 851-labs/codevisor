import Foundation
import ACPKit

extension SessionController {
  @discardableResult
  public func reconcileExistingSession(_ session: ChatSession) -> Bool {
    guard serverSession.map(ExistingSessionRuntimeState.init) != ExistingSessionRuntimeState(session)
    else { return false }
    configureExistingSession(session)
    return true
  }

  public func configureExistingSession(_ session: ChatSession) {
    let identityChanged =
      serverSession?.id != session.id
      || resumeAgentSessionId != session.agentSessionId
    let wasDraft = acceptsNewChatDefaults
    serverSession = session
    resumeAgentSessionId = session.agentSessionId
    if session.agentSessionId?.isEmpty == false {
      draftModelAvailability = nil
    }
    if wasDraft, !acceptsNewChatDefaults {
      pendingConfiguration.restoreValues([:])
      clearAutomaticSelection()
    }
    if !session.harnessId.isEmpty {
      selectedHarnessId = session.harnessId
    }
    guard model == nil else { return }
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

  public var configOptions: [SessionConfigOption] {
    acceptsNewChatDefaults ? draftConfigOptions : existingChatConfigOptions
  }

  private var draftConfigOptions: [SessionConfigOption] {
    guard let harnessId = activeHarnessId else { return [] }
    let pendingConfig = pendingConfiguration.values(for: harnessId) ?? [:]
    let cachedOptions = configCache.options(forHarness: harnessId, onServer: project.serverId)
    var options =
      configOptionsByHarness[harnessId].flatMap {
        $0.isEmpty && !cachedOptions.isEmpty ? nil : $0
      } ?? cachedOptions
    if let catalogModel = Self.modelOption(in: options),
      let staged = pendingConfig[catalogModel.id], !staged.isEmpty,
      let resolved = draftModelSettings[
        Self.draftModelSettingsKey(harnessId: harnessId, model: staged)]
    {
      options = resolved
    }
    if let index = options.firstIndex(where: Self.isModelOption),
      pendingConfig[options[index].id]?.isEmpty != false
    {
      options[index].currentValue = ""
    }
    return applying(pendingConfig, to: options)
  }

  private var existingChatConfigOptions: [SessionConfigOption] {
    guard let harnessId = activeHarnessId else { return [] }
    let pending = pendingConfiguration.values(for: harnessId) ?? [:]
    var options: [SessionConfigOption]
    if let model, !model.configOptions.isEmpty {
      options = model.configOptions
    } else {
      let saved = existingChatSelections
      let definitions =
        configOptionsByHarness[harnessId].flatMap { $0.isEmpty ? nil : $0 }
        ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
      options = SavedSessionConfigOptions.project(definitions: definitions, selections: saved)
    }
    if unavailableExistingModelValue != nil,
      let index = options.firstIndex(where: Self.isModelOption)
    {
      options[index].currentValue = ""
    }
    return applying(pending, to: options)
  }

  var existingChatSelections: [String: String] {
    var values = firstSendSelections
    values.merge(serverSession?.configSelections ?? [:]) { _, saved in saved }
    return values.filter { !$0.value.isEmpty }
  }

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
    SavedSessionConfigOptions.isModelOption(option)
  }

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

  private static let modelMenuCategories: Set<String> = [
    SessionConfigOption.Category.model,
    SessionConfigOption.Category.thoughtLevel,
    SessionConfigOption.Category.speed,
  ]

  static let rememberedConfigCategories: Set<String> = [
    SessionConfigOption.Category.model,
    SessionConfigOption.Category.thoughtLevel,
    SessionConfigOption.Category.speed,
    SessionConfigOption.Category.modelConfig,
  ]

  public var modelOption: SessionConfigOption? {
    configOptions.first { $0.category == SessionConfigOption.Category.model && !$0.options.isEmpty }
  }

  public var thoughtLevelOptions: [SessionConfigOption] {
    configOptions.filter { $0.category == SessionConfigOption.Category.thoughtLevel && !$0.options.isEmpty }
  }

  public var speedOption: SessionConfigOption? {
    configOptions.first { $0.category == SessionConfigOption.Category.speed && !$0.options.isEmpty }
  }

  public var hasModelMenu: Bool {
    modelOption != nil || !thoughtLevelOptions.isEmpty || speedOption != nil
  }

  public var isLoadingModelMenu: Bool {
    if !acceptsNewChatDefaults {
      return isAwaitingExistingChatModel
    }
    guard !hasModelMenu else { return false }
    if isRefreshingHarnessCapabilities { return !hasSettledCatalogKnowledge }
    if isConnecting || isConnectingToHarness { return true }
    return model == nil && preparationState == .loading
  }

  private var isAwaitingExistingChatModel: Bool {
    if unavailableExistingModelValue != nil { return false }
    if let option = modelOption, !option.currentValue.isEmpty { return false }
    if case .failed = status { return false }
    if case .failed = configurationValidationState { return false }
    if isConnectingToHarness { return true }
    return model == nil && (hasExistingAgentSession || hasSentFirst || isConnecting)
  }

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
      pendingConfiguration.stage(value, for: configId, in: harnessId)
      accepted = await model.configuration.set(configId: configId, value: value)
      pendingConfiguration.clearAppliedValue(value, for: configId, in: harnessId)
      if let connectedHarnessId, !model.configOptions.isEmpty {
        configOptionsByHarness[connectedHarnessId] = model.configOptions
      }
    } else if let harnessId = wasDraft ? selectedHarnessId : harnessId {
      pendingConfiguration.stage(value, for: configId, in: harnessId)
    }
    if accepted, isModelChange {
      if previousValue != value {
        captureModelSelected(modelId: value, previousModelId: previousValue)
      }
      configurationAdjustmentMessage = nil
      draftModelAvailability = nil
      acknowledgedUnavailableModelValue =
        serverSession?.unavailableConfigSelections?[configId] ?? acknowledgedUnavailableModelValue
      model?.clearModelFallback()
    }
    if accepted, wasDraft, acceptsNewChatDefaults,
      Self.rememberedConfigCategories.contains(optionBeforeChange?.category ?? "")
        || isModelChange,
      let harnessId = selectedHarnessId
    {
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

  func resolveAutomaticSelectionIfNeeded() async {
    guard automaticSelectionNeedsResolution, let intent = automaticSelectionIntent else {
      return
    }
    await resolveRetargetedComposerSelection(intent, targetServerId: project.serverId)
  }
}

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
