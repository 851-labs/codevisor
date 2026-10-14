import Foundation
import ACPKit

extension SessionController {
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

  public var selectedModelName: String? {
    if let pendingModelPick, pendingModelPick.harnessId == activeHarnessId {
      return pendingModelPick.name
    }
    guard let option = modelOption, !option.currentValue.isEmpty else { return nil }
    return option.options.first { $0.value == option.currentValue }?.name
  }

  public var requiresModelSelection: Bool {
    modelOption != nil && selectedModelName == nil
  }

  public var hasModelSettings: Bool {
    configOptions.contains { option in
      !option.options.isEmpty
        && !Self.isModelOption(option)
        && option.category != SessionConfigOption.Category.mode
        && option.id != "mode"
    }
  }

  public var modelPickerPresentation: ModelPickerPresentation {
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
    guard var pending = pendingConfiguration.values(for: target.harnessId) else { return }
    for option in capability.configOptions where !Self.isModelOption(option) {
      if let value = pending[option.id], !option.options.contains(where: { $0.value == value }) {
        pending[option.id] = nil
      }
    }
    pendingConfiguration.replaceValues(pending, for: target.harnessId)
  }

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
    let modelId = modelOption?.id ?? modelConfigId(forHarness: harnessId)
    let accepted = await setConfigOption(modelId, value)
    guard accepted, modelPickRevision == revision else { return }
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
