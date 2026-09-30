import Foundation
import ACPKit

extension SessionController {
  public func draftSnapshot() -> ComposerDraftStore.Draft {
    ComposerDraftStore.Draft(
      // A scratch folder belongs to the chat being sent, never to the next
      // draft: a draft mid-first-send records the CHOICE of no project.
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

    // Drafts written before immediate defaults persistence need one
    // compatibility promotion. Current drafts deliberately stay separate:
    // an automatically carried machine-switch selection must not become a
    // machine default merely because the app relaunched.
    if !draft.usesImmediateDefaultsPersistence, let composerDefaults {
      for (harnessId, configValues) in draft.configByHarness {
        composerDefaults.rememberConfigSelections(
          in: resolvedComposerDefaultsScope,
          harnessId: harnessId,
          configValues: configValues
        )
      }
      composerDefaults.rememberHarnessSelection(
        in: resolvedComposerDefaultsScope,
        harnessId: draft.selectedHarnessId
      )
    }

    // Server file ids are not assumed to survive indefinitely. Re-upload
    // the staged files and produce fresh refs for the next send.
    attachments.prepareRestoredFiles()
  }

  func draftDidChange() {
    guard !isRestoringDraft, isDraft, let onDraftChange else { return }
    onDraftChange(draftSnapshot())
  }

  // MARK: - Remembered composer defaults

  /// True until the first send creates the real session — the window where
  /// remembered defaults are seeded into pending config.
  private var isDraft: Bool { serverSession == nil && !hasSentFirst }

  /// Eagerly-created workspace chat records still behave like drafts until
  /// their first agent session exists. They need inherited configuration
  /// even though `serverSession` is already non-nil.
  var acceptsNewChatDefaults: Bool {
    !hasSentFirst
      && resumeAgentSessionId?.isEmpty != false
      && serverSession?.agentSessionId?.isEmpty != false
  }

  /// Every unsent composer — the standalone page, a new tab, or a split —
  /// reads and writes the New Chat defaults of the machine it targets.
  var resolvedComposerDefaultsScope: ComposerDefaultsStore.Scope {
    .newWorkspace(serverId: project.serverId)
  }

  /// Seeds a new-chat draft from the last explicit selections on this
  /// machine. Called once when a draft composer is made.
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

  /// Captures portable selection values before a machine switch. Capability
  /// definitions never cross machines; the destination validates these ids
  /// and values against its own catalog.
  func currentComposerSelectionIntent() -> ComposerSelectionIntent? {
    guard let harnessId = selectedHarnessId, !harnessId.isEmpty else { return nil }
    var configValues = rememberedConfigValues
    configValues.merge(pendingConfiguration.values(for: harnessId) ?? [:]) { _, pending in pending }
    let selectedModel = Self.modelOption(in: configOptions)
    if let selectedModel, !selectedModel.currentValue.isEmpty {
      configValues[selectedModel.id] = selectedModel.currentValue
    }
    // A model this machine no longer lists is still the draft's choice;
    // another machine may offer it.
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

  /// Resolves the selected harness whenever a fresh destination catalog is
  /// applied. A compatible outgoing harness/model wins; otherwise the
  /// destination machine's durable profile wins; the catalog's first harness
  /// is only the final fallback.
  func applyNewChatSelectionPolicy(_ capabilities: [ServerHarnessCapability]) {
    let availableIds = Set(capabilities.map(\.harness.id))
    if let intent = automaticSelectionIntent,
      let capability = capabilities.first(where: { $0.harness.id == intent.harnessId }),
      canCarry(intent, to: capability)
    {
      selectedHarnessId = intent.harnessId
      var carried = intent.configValues
      if let modelValue = intent.modelValue,
        let model = Self.modelOption(in: capability.configOptions)
      {
        carried[model.id] = modelValue
      }
      pendingConfiguration.replaceValues(carried, for: intent.harnessId)
      // Add destination-only remembered values (for example a speed
      // tier absent from the source snapshot) without replacing carried
      // values. The live resolver validates the complete set below.
      seedRememberedConfig()
      automaticSelectionNeedsResolution = true
      return
    }

    if let intent = automaticSelectionIntent {
      clearAutomaticSelection()
      // The destination runs the carried harness but does not list the
      // carried model: keep the pick's other values and ask the server
      // whether the model was renamed or withdrawn (rule: a missing
      // model is never silently replaced).
      if availableIds.contains(intent.harnessId), let modelValue = intent.modelValue {
        selectedHarnessId = intent.harnessId
        let destinationOptions =
          capabilities.first { $0.harness.id == intent.harnessId }?.configOptions ?? []
        // Other carried settings survive where the destination offers them.
        pendingConfiguration.replaceValues(
          intent.configValues.filter { configId, value in
            guard let option = destinationOptions.first(where: { $0.id == configId }) else {
              return false
            }
            return !Self.isModelOption(option) && option.options.contains { $0.value == value }
          }, for: intent.harnessId)
        markDraftModel(
          modelValue,
          name: intent.modelName ?? modelValue,
          harnessId: intent.harnessId,
          checking: true
        )
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

  private func canCarry(
    _ intent: ComposerSelectionIntent,
    to capability: ServerHarnessCapability
  ) -> Bool {
    guard let modelValue = intent.modelValue else { return true }
    guard let model = Self.modelOption(in: capability.configOptions) else { return false }
    return model.options.contains { $0.value == modelValue }
  }

  static func modelOption(in options: [SessionConfigOption]) -> SessionConfigOption? {
    options.first {
      ($0.category == SessionConfigOption.Category.model || $0.id == "model")
        && !$0.options.isEmpty
    }
  }

  /// Stages the remembered config selections for the selected harness as
  /// pending edits so the pickers show them and the agent applies them on
  /// connect. Values are validated against the known option lists when
  /// available; unknown lists trust the stored values and let the live
  /// agent correct them. A remembered (or staged) model the known list
  /// does not carry is never replaced by another model: the draft asks the
  /// server whether it was renamed, else asks the user for a new pick.
  func seedRememberedConfig() {
    guard let harnessId = selectedHarnessId else { return }
    let remembered =
      composerDefaults?.configSelections(
        forHarness: harnessId,
        in: resolvedComposerDefaultsScope
      ) ?? [:]
    let options =
      configOptionsByHarness[harnessId]
      ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
    guard !options.isEmpty else {
      pendingConfiguration.mergeDefaults(remembered, for: harnessId)
      return
    }
    // The catalog's settings describe the harness's own default model. When
    // the draft's model is a different one, the catalog cannot judge its
    // settings: keep them queued until that model's settings are inspected
    // (`resolveDraftModelSettingsIfNeeded`), which keeps valid values and
    // drops the rest to the model's defaults.
    let catalogModel = Self.modelOption(in: options)
    let wantedModel = catalogModel.flatMap { model in
      (pendingConfiguration.value(for: model.id, in: harnessId)).flatMap { $0.isEmpty ? nil : $0 }
        ?? remembered[model.id]
    }
    let catalogDescribesModel = wantedModel == nil || wantedModel == catalogModel?.currentValue
    for (configId, value) in remembered {
      // A speed option can be absent until its remembered model is
      // restored. Keep it queued and validate it against the live agent
      // after the model change makes the option available.
      guard let option = options.first(where: { $0.id == configId }) else {
        if configId == "speed" || !catalogDescribesModel,
          pendingConfiguration.value(for: configId, in: harnessId) == nil
        {
          pendingConfiguration.stage(value, for: configId, in: harnessId)
        }
        continue
      }
      // The model is validated below, together with any staged pick.
      if Self.isModelOption(option) { continue }
      guard !catalogDescribesModel || option.options.contains(where: { $0.value == value }) else {
        continue
      }
      if pendingConfiguration.value(for: configId, in: harnessId) == nil {
        pendingConfiguration.stage(value, for: configId, in: harnessId)
      }
    }
    validateDraftModel(harnessId: harnessId, options: options, remembered: remembered)
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
    // Already being checked or known unavailable for this value.
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

  /// Takes a draft's missing model out of the staged values and records
  /// it for the "Select a model" chip (and, once confirmed, the notice).
  func markDraftModel(_ value: String, name: String, harnessId: String, checking: Bool) {
    let modelId = modelConfigId(forHarness: harnessId)
    pendingConfiguration.removeValue(for: modelId, in: harnessId)
    draftModelAvailability =
      checking
      ? .checking(harnessId: harnessId, value: value, name: name)
      : .unavailable(harnessId: harnessId, value: value, name: name)
  }

  /// Asks the server about a draft model the catalog does not list. An id
  /// the server reconciled to a new one is adopted (and becomes the New
  /// Chat default); anything else is reported as no longer available.
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
        // Without the field, an older server cannot tell a rename from
        // a harness default; only an explicit reconciliation counts.
        capability.unappliedConfigSelections != nil
      else {
        markUnavailable()
        return
      }
      draftModelAvailability = nil
      configOptionsByHarness[harnessId] = capability.configOptions
      pendingConfiguration.stage(resolved.currentValue, for: resolved.id, in: harnessId)
      if acceptsNewChatDefaults,
        composerDefaults?.configSelections(
          forHarness: harnessId,
          in: resolvedComposerDefaultsScope
        )[resolved.id] == value
      {
        composerDefaults?.rememberConfigSelections(
          in: resolvedComposerDefaultsScope,
          harnessId: harnessId,
          configValues: [resolved.id: resolved.currentValue]
        )
      }
    } catch {
      markUnavailable()
    }
  }

  /// Remembered config categories (model, reasoning, speed, model config)
  /// as currently selected — what composer memory captures.
  var rememberedConfigValues: [String: String] {
    let values =
      configOptions
      .filter { Self.rememberedConfigCategories.contains($0.category ?? "") }
      .filter { !$0.currentValue.isEmpty }
      .map { ($0.id, $0.currentValue) }
    return Dictionary(values) { _, last in last }
  }
}
