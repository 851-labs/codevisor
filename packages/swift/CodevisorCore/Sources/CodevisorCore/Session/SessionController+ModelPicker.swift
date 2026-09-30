import Foundation
import ACPKit

/// Model picker state and actions: what the model and parameter chips show,
/// when a model must be picked before sending, and the pick itself.
extension SessionController {
  /// An existing chat's saved model its runtime no longer offers, until
  /// the user picks a replacement.
  var unavailableExistingModelValue: String? {
    guard !acceptsNewChatDefaults,
      let unavailable = serverSession?.unavailableConfigSelections,
      !unavailable.isEmpty,
      let harnessId = activeHarnessId
    else { return nil }
    let modelId = modelConfigId(forHarness: harnessId)
    guard let value = unavailable[modelId], !value.isEmpty,
      value != acknowledgedUnavailableModelValue,
      pendingConfiguration.value(for: modelId, in: harnessId) == nil
    else { return nil }
    return value
  }

  /// "<Model> is no longer available. Select another model." — shown as a
  /// composer notice until the user picks a model.
  public var modelUnavailableMessage: String? {
    guard pendingModelPick == nil else { return nil }
    if acceptsNewChatDefaults {
      guard case let .unavailable(harnessId, value, name) = draftModelAvailability,
        harnessId == activeHarnessId,
        value != dismissedUnavailableModelNotice
      else { return nil }
      return Self.modelUnavailableMessage(name: name)
    }
    guard let value = unavailableExistingModelValue, let harnessId = activeHarnessId,
      value != dismissedUnavailableModelNotice
    else {
      return nil
    }
    let definitions =
      (configOptionsByHarness[harnessId] ?? [])
      + configCache.options(forHarness: harnessId, onServer: project.serverId)
    let name =
      definitions.lazy
      .filter(Self.isModelOption)
      .compactMap { $0.options.first { $0.value == value }?.name }
      .first ?? value
    return Self.modelUnavailableMessage(name: name)
  }

  /// Hides the "no longer available" notice. The model chip keeps asking
  /// for a pick and sending stays blocked until the user chooses one.
  public func dismissModelUnavailableNotice() {
    if case let .unavailable(_, value, _) = draftModelAvailability {
      dismissedUnavailableModelNotice = value
    } else if let value = unavailableExistingModelValue {
      dismissedUnavailableModelNotice = value
    }
  }

  static func modelUnavailableMessage(name: String) -> String {
    "\(name) is no longer available. Select another model."
  }

  /// The selected model's name, or nil when nothing valid is selected.
  public var selectedModelName: String? {
    if let pendingModelPick, pendingModelPick.harnessId == activeHarnessId {
      return pendingModelPick.name
    }
    guard let option = modelOption, !option.currentValue.isEmpty else { return nil }
    return option.options.first { $0.value == option.currentValue }?.name
  }

  /// Sending needs a model whenever the harness exposes a model option.
  public var requiresModelSelection: Bool {
    modelOption != nil && selectedModelName == nil
  }

  /// Model-owned parameter controls (thinking, speed, model config).
  public var hasModelSettings: Bool {
    configOptions.contains { option in
      !option.options.isEmpty
        && !Self.isModelOption(option)
        && option.category != SessionConfigOption.Category.mode
        && option.id != "mode"
    }
  }

  /// The single source of truth for the model and parameter chips.
  public var modelPickerPresentation: ModelPickerPresentation {
    // A draft's remembered model being checked with the server (renamed
    // or withdrawn?) has no value to show yet: spin rather than flash
    // "Select a model" before the answer. Only a draft asks; an existing
    // chat's model is its own and never waits on this check.
    let isCheckingDraftModel: Bool =
      if acceptsNewChatDefaults, case let .checking(harnessId, _, _) = draftModelAvailability,
        harnessId == activeHarnessId
      {
        true
      } else {
        false
      }
    return ModelPickerPresentation(
      isModelListKnown: pendingModelPick != nil || (!isLoadingModelMenu && !isCheckingDraftModel),
      selectedModelName: selectedModelName,
      hasSettings: hasModelSettings,
      isResolvingSettings: pendingModelPick != nil || isResolvingModelConfiguration
        || (resolvingDraftModelSettingsKey != nil && acceptsNewChatDefaults)
    )
  }

  static func draftModelSettingsKey(harnessId: String, model: String) -> String {
    "\(harnessId)|\(model)"
  }

  /// The draft's staged model when the machine catalog describes another
  /// model (or none), so that model's own settings must be inspected.
  var draftModelNeedingSettings: (harnessId: String, model: String, key: String)? {
    guard acceptsNewChatDefaults, model == nil, let harnessId = selectedHarnessId else { return nil }
    let catalog =
      configOptionsByHarness[harnessId].flatMap { $0.isEmpty ? nil : $0 }
      ?? configCache.options(forHarness: harnessId, onServer: project.serverId)
    guard let catalogModel = Self.modelOption(in: catalog),
      let staged = pendingConfiguration.value(for: catalogModel.id, in: harnessId), !staged.isEmpty,
      catalogModel.options.contains(where: { $0.value == staged }),
      staged != catalogModel.currentValue
    else { return nil }
    let key = Self.draftModelSettingsKey(harnessId: harnessId, model: staged)
    guard draftModelSettings[key] == nil else { return nil }
    return (harnessId, staged, key)
  }

  /// Inspects a draft's staged model once to learn its own settings. The
  /// parameters chip spins meanwhile. Settings the new model still offers
  /// keep their values; the rest fall back to that model's defaults. A
  /// failed inspection leaves the model untouched and simply shows no
  /// model-specific settings.
  func resolveDraftModelSettingsIfNeeded() async {
    guard let target = draftModelNeedingSettings, let client = serverClient else { return }
    guard resolvingDraftModelSettingsKey != target.key else { return }
    resolvingDraftModelSettingsKey = target.key
    defer {
      if resolvingDraftModelSettingsKey == target.key { resolvingDraftModelSettingsKey = nil }
    }
    let serverId = project.serverId
    let requested = pendingConfiguration.values(for: target.harnessId) ?? [:]
    guard
      let response = try? await client.capabilities(
        cwd: capabilityCwd,
        harnessId: target.harnessId,
        configSelections: requested
      ),
      project.serverId == serverId,
      let capability = response.harnesses.first(where: { $0.harness.id == target.harnessId }),
      let resolvedModel = Self.modelOption(in: capability.configOptions),
      resolvedModel.currentValue == target.model
    else { return }
    draftModelSettings[target.key] = capability.configOptions
    // Drop staged settings the model does not accept; its default shows.
    guard var pending = pendingConfiguration.values(for: target.harnessId) else { return }
    for option in capability.configOptions where !Self.isModelOption(option) {
      if let value = pending[option.id], !option.options.contains(where: { $0.value == value }) {
        pending[option.id] = nil
      }
    }
    pendingConfiguration.replaceValues(pending, for: target.harnessId)
  }

  /// The model picker's action. The chip names the pick immediately; the
  /// parameters chip waits for that model's settings. Thinking and speed
  /// keep their previous values when the new model still offers them.
  public func chooseModel(_ value: String, name: String, harnessId: String) async {
    modelPickRevision &+= 1
    let revision = modelPickRevision
    stagedModelNames[value] = name
    pendingModelPick = PendingModelPick(harnessId: harnessId, value: value, name: name)
    defer {
      if modelPickRevision == revision { pendingModelPick = nil }
    }
    let carriedSettings = Dictionary(
      configOptions
        .filter {
          $0.category == SessionConfigOption.Category.thoughtLevel
            || $0.category == SessionConfigOption.Category.speed
        }
        .filter { !$0.currentValue.isEmpty }
        .map { ($0.id, $0.currentValue) }
    ) { first, _ in first }
    if activeHarnessId != harnessId {
      guard canChooseHarness else { return }
      await selectHarness(harnessId)
      guard modelPickRevision == revision, activeHarnessId == harnessId else { return }
    }
    // The live list may differ from the menu that offered this model (a
    // harness switch reloads it). A value the list does not carry stays
    // staged rather than being dropped or swapped for another model.
    let modelId = modelOption?.id ?? modelConfigId(forHarness: harnessId)
    let accepted = await setConfigOption(modelId, value)
    guard accepted, modelPickRevision == revision else { return }
    // A draft learns the new model's own settings before carrying values.
    await resolveDraftModelSettingsIfNeeded()
    guard modelPickRevision == revision else { return }
    for option in configOptions where carriedSettings[option.id] != nil {
      guard let previous = carriedSettings[option.id],
        option.currentValue != previous,
        option.options.contains(where: { $0.value == previous })
      else { continue }
      await setConfigOption(option.id, previous)
      guard modelPickRevision == revision else { return }
    }
  }
}
