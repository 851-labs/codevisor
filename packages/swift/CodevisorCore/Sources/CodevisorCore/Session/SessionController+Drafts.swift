import Foundation
import ACPKit

extension SessionController {
  public func draftSnapshot() -> ComposerDraftStore.Draft {
    ComposerDraftStore.Draft(
      projectId: project.isScratch ? Project.runTargetPlaceholderID : project.id,
      projectServerId: project.serverId,
      composerText: composerText,
      attachments: composerAttachments.compactMap {
        guard $0.state != .loading, let fileURL = $0.fileURL else { return nil }
        return ComposerDraftStore.DraftAttachment(
          id: $0.id,
          name: $0.name,
          mimeType: $0.mimeType,
          kind: $0.kind.rawValue,
          fileURL: fileURL
        )
      },
      selectedHarnessId: selectedHarnessId,
      configByHarness: pendingConfiguration.valuesByHarness,
      modeId: pendingConfiguration.modeId,
      isGoalComposerArmed: isGoalComposerArmed,
      isGoalEditing: isGoalEditing,
      composerTextBeforeGoalEdit: composerTextBeforeGoalEdit,
      usesImmediateDefaultsPersistence: true,
      selectionWasAutomaticallyCarried: automaticSelectionIntent != nil
    )
  }

  public func restoreDraft(_ draft: ComposerDraftStore.Draft) {
    isRestoringDraft = true
    composerText = draft.composerText
    let restoredAttachments = draft.attachments.map {
      ComposerAttachment(
        id: $0.id,
        name: $0.name,
        mimeType: $0.mimeType,
        kind: Attachment.Kind(rawValue: $0.kind) ?? .file,
        fileURL: $0.fileURL,
        state: .uploading
      )
    }
    attachments.restore(restoredAttachments)
    selectedHarnessId = draft.selectedHarnessId
    pendingConfiguration.restoreValues(draft.configByHarness)
    pendingConfiguration.setMode(draft.modeId)
    isGoalComposerArmed = draft.isGoalComposerArmed
    isGoalEditing = draft.isGoalEditing
    composerTextBeforeGoalEdit = draft.composerTextBeforeGoalEdit
    isRestoringDraft = false

    automaticSelectionIntent =
      draft.selectionWasAutomaticallyCarried ? currentComposerSelectionIntent() : nil
    automaticSelectionNeedsResolution = automaticSelectionIntent != nil

    if !draft.usesImmediateDefaultsPersistence, let composerDefaults {
      for (harnessId, configValues) in draft.configByHarness {
        composerDefaults.rememberConfigSelections(
          harnessId: harnessId,
          modelOptionId: modelConfigId(forHarness: harnessId),
          configValues: configValues
        )
      }
      composerDefaults.rememberHarnessSelection(
        in: resolvedComposerDefaultsScope,
        harnessId: draft.selectedHarnessId
      )
    }

    attachments.prepareRestoredFiles()
  }

  func draftDidChange() {
    guard !isRestoringDraft, isDraft, let onDraftChange else { return }
    onDraftChange(draftSnapshot())
  }

  private var isDraft: Bool { serverSession == nil && !hasSentFirst }

  var acceptsNewChatDefaults: Bool {
    !hasSentFirst
      && resumeAgentSessionId?.isEmpty != false
      && serverSession?.agentSessionId?.isEmpty != false
  }

  var resolvedComposerDefaultsScope: ComposerDefaultsStore.Scope {
    .newWorkspace(serverId: project.serverId)
  }

  public func applyComposerDefaults() {
    guard let composerDefaults, acceptsNewChatDefaults else { return }
    if let harnessId = composerDefaults.lastHarnessId(for: resolvedComposerDefaultsScope),
      !harnessId.isEmpty,
      harnesses.isEmpty || harnesses.contains(where: { $0.id == harnessId })
    {
      selectedHarnessId = harnessId
    }
    seedRememberedConfig()
  }

  func currentComposerSelectionIntent() -> ComposerSelectionIntent? {
    guard let harnessId = selectedHarnessId, !harnessId.isEmpty else { return nil }
    var configValues = rememberedConfigValues
    configValues.merge(pendingConfiguration.values(for: harnessId) ?? [:]) { _, pending in pending }
    let selectedModel = Self.modelOption(in: configOptions)
    if let selectedModel, !selectedModel.currentValue.isEmpty {
      configValues[selectedModel.id] = selectedModel.currentValue
    }
    let unavailableModel =
      draftModelAvailability?.harnessId == harnessId ? draftModelAvailability : nil
    let modelValue =
      selectedModel.flatMap { $0.currentValue.isEmpty ? nil : $0.currentValue }
      ?? unavailableModel?.value
      ?? configValues["model"]
    return ComposerSelectionIntent(
      harnessId: harnessId,
      configValues: configValues.filter { !$0.value.isEmpty },
      modelValue: modelValue,
      modelName: selectedModelName ?? unavailableModel?.name
    )
  }

  func applyNewChatSelectionPolicy(_ capabilities: [ServerHarnessCapability]) {
    let availableIds = Set(capabilities.map(\.harness.id))
    if let intent = automaticSelectionIntent,
      let capability = capabilities.first(where: { $0.harness.id == intent.harnessId }),
      intent.canCarry(to: capability)
    {
      carrySelection(intent, to: capability)
      return
    }

    if let intent = automaticSelectionIntent {
      clearAutomaticSelection()
      if availableIds.contains(intent.harnessId), let modelValue = intent.modelValue {
        stageUnavailableSelection(intent, modelValue: modelValue, capabilities: capabilities)
        return
      }
      pendingConfiguration.replaceValues(nil, for: intent.harnessId)
      applyDestinationMachineDefaults(availableHarnessIds: availableIds)
      return
    }

    if let selectedHarnessId, availableIds.contains(selectedHarnessId) {
      seedRememberedConfig()
      return
    }
    applyDestinationMachineDefaults(availableHarnessIds: availableIds)
  }

  private func carrySelection(
    _ intent: ComposerSelectionIntent,
    to capability: ServerHarnessCapability
  ) {
    selectedHarnessId = intent.harnessId
    let carried = intent.carriedConfigValues(to: capability)
    pendingConfiguration.replaceValues(carried, for: intent.harnessId)
    seedRememberedConfig()
    automaticSelectionNeedsResolution = true
  }

  private func stageUnavailableSelection(
    _ intent: ComposerSelectionIntent,
    modelValue: String,
    capabilities: [ServerHarnessCapability]
  ) {
    selectedHarnessId = intent.harnessId
    let destinationOptions =
      capabilities.first { $0.harness.id == intent.harnessId }?.configOptions ?? []
    pendingConfiguration.replaceValues(
      intent.compatibleConfigValues(in: destinationOptions), for: intent.harnessId)
    markDraftModel(
      modelValue,
      name: intent.modelName ?? modelValue,
      harnessId: intent.harnessId,
      checking: true
    )
  }

  func applyDestinationMachineDefaults(availableHarnessIds: Set<String>? = nil) {
    let availableIds = availableHarnessIds ?? Set(harnesses.map(\.id))
    let rememberedHarness = composerDefaults?.lastHarnessId(for: resolvedComposerDefaultsScope)
    if let rememberedHarness, availableIds.contains(rememberedHarness) {
      selectedHarnessId = rememberedHarness
    } else {
      selectedHarnessId = harnesses.first(where: { availableIds.contains($0.id) })?.id
    }
    seedRememberedConfig()
  }

  func clearAutomaticSelection() {
    automaticSelectionIntent = nil
    automaticSelectionNeedsResolution = false
  }

  static func modelOption(in options: [SessionConfigOption]) -> SessionConfigOption? {
    options.first {
      ($0.category == SessionConfigOption.Category.model || $0.id == "model")
        && !$0.options.isEmpty
    }
  }

  func seedRememberedConfig() {
    guard let harnessId = selectedHarnessId else { return }
    let wantedModel = wantedDraftModel(harnessId: harnessId)
    let remembered = rememberedConfigSelections(forHarness: harnessId, model: wantedModel)
    let options =
      configOptionsByHarness[harnessId]
      ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
    guard !options.isEmpty else {
      pendingConfiguration.mergeDefaults(remembered, for: harnessId)
      return
    }

    let modelOptions = optionsDescribing(model: wantedModel, harnessId: harnessId, catalog: options)
    for (configId, value) in remembered where pendingConfiguration.value(for: configId, in: harnessId) == nil {
      guard Self.rememberedValueFits(configId, value, catalog: options, modelOptions: modelOptions) else { continue }
      pendingConfiguration.stage(value, for: configId, in: harnessId)
    }
    validateDraftModel(harnessId: harnessId, options: options, remembered: remembered)
  }

  private func wantedDraftModel(harnessId: String) -> String? {
    let modelId = modelConfigId(forHarness: harnessId)
    if let staged = pendingConfiguration.value(for: modelId, in: harnessId), !staged.isEmpty {
      return staged
    }
    return rememberedConfigSelections(forHarness: harnessId, model: nil)[modelId]
  }

  private func optionsDescribing(
    model: String?,
    harnessId: String,
    catalog: [SessionConfigOption]
  ) -> [SessionConfigOption]? {
    guard let model, let catalogModel = Self.modelOption(in: catalog), model != catalogModel.currentValue else {
      return catalog
    }
    return draftModelSettings[Self.draftModelSettingsKey(harnessId: harnessId, model: model)]
  }

  private static func rememberedValueFits(
    _ configId: String,
    _ value: String,
    catalog: [SessionConfigOption],
    modelOptions: [SessionConfigOption]?
  ) -> Bool {
    if let option = catalog.first(where: { $0.id == configId }), isModelOption(option) { return false }
    guard let modelOptions else { return true }
    guard let option = modelOptions.first(where: { $0.id == configId }) else { return configId == "speed" }
    return option.options.contains { $0.value == value }
  }

  private func validateDraftModel(
    harnessId: String,
    options: [SessionConfigOption],
    remembered: [String: String]
  ) {
    guard let modelOption = Self.modelOption(in: options) else { return }
    let staged = pendingConfiguration.value(for: modelOption.id, in: harnessId)
    let wanted =
      staged.flatMap { $0.isEmpty ? nil : $0 }
      ?? remembered[modelOption.id]
      ?? (draftModelAvailability?.harnessId == harnessId ? draftModelAvailability?.value : nil)
    guard let wanted, !wanted.isEmpty else { return }
    if modelOption.options.contains(where: { $0.value == wanted }) {
      pendingConfiguration.stage(wanted, for: modelOption.id, in: harnessId)
      if draftModelAvailability?.harnessId == harnessId { draftModelAvailability = nil }
      return
    }
    if draftModelAvailability?.harnessId == harnessId, draftModelAvailability?.value == wanted {
      pendingConfiguration.removeValue(for: modelOption.id, in: harnessId)
      return
    }
    let name =
      stagedModelNames[wanted]
      ?? configOptionsByHarness[harnessId].flatMap(Self.modelOption(in:))?
      .options.first(where: { $0.value == wanted })?.name
      ?? wanted
    markDraftModel(wanted, name: name, harnessId: harnessId, checking: true)
  }

  func markDraftModel(_ value: String, name: String, harnessId: String, checking: Bool) {
    let modelId = modelConfigId(forHarness: harnessId)
    pendingConfiguration.removeValue(for: modelId, in: harnessId)
    draftModelAvailability =
      checking
      ? .checking(harnessId: harnessId, value: value, name: name)
      : .unavailable(harnessId: harnessId, value: value, name: name)
  }

  func resolveDraftModelAvailabilityIfNeeded() async {
    guard case let .checking(harnessId, value, name) = draftModelAvailability else { return }
    let modelId = modelConfigId(forHarness: harnessId)
    func markUnavailable() {
      guard draftModelAvailability == .checking(harnessId: harnessId, value: value, name: name)
      else { return }
      draftModelAvailability = .unavailable(harnessId: harnessId, value: value, name: name)
    }
    guard let client = serverClient else {
      markUnavailable()
      return
    }
    var requested = pendingConfiguration.values(for: harnessId) ?? [:]
    requested[modelId] = value
    let serverId = project.serverId
    do {
      let response = try await client.capabilities(
        cwd: capabilityCwd,
        harnessId: harnessId,
        configSelections: requested
      )
      guard draftModelAvailability == .checking(harnessId: harnessId, value: value, name: name),
        project.serverId == serverId
      else { return }
      guard let capability = response.harnesses.first(where: { $0.harness.id == harnessId }),
        let resolved = Self.modelOption(in: capability.configOptions),
        capability.unappliedConfigSelections?[resolved.id] == nil,
        !resolved.currentValue.isEmpty,
        resolved.options.contains(where: { $0.value == resolved.currentValue }),
        capability.unappliedConfigSelections != nil
      else {
        markUnavailable()
        return
      }
      draftModelAvailability = nil
      configOptionsByHarness[harnessId] = capability.configOptions
      pendingConfiguration.stage(resolved.currentValue, for: resolved.id, in: harnessId)
      if acceptsNewChatDefaults,
        rememberedConfigSelections(forHarness: harnessId, model: nil)[resolved.id] == value
      {
        composerDefaults?.rememberConfigSelections(
          harnessId: harnessId,
          modelOptionId: resolved.id,
          configValues: rememberedConfigSelections(forHarness: harnessId, model: value)
            .merging([resolved.id: resolved.currentValue]) { _, reconciled in reconciled }
        )
      }
    } catch {
      markUnavailable()
    }
  }

  var rememberedConfigValues: [String: String] {
    let values =
      configOptions
      .filter { Self.rememberedConfigCategories.contains($0.category ?? "") }
      .filter { !$0.currentValue.isEmpty }
      .map { ($0.id, $0.currentValue) }
    return Dictionary(values) { _, last in last }
  }
}
