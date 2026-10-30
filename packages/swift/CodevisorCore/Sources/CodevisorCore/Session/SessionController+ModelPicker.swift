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
    if activeHarnessId != harnessId {
      guard canChooseHarness else { return }
      await selectHarness(harnessId)
      guard modelPickRevision == revision, activeHarnessId == harnessId else { return }
    }
    let modelId = modelOption?.id ?? modelConfigId(forHarness: harnessId)
    if acceptsNewChatDefaults { clearDraftModelSettings(harnessId: harnessId) }
    let accepted = await setConfigOption(modelId, value)
    guard accepted, modelPickRevision == revision else { return }

    if acceptsNewChatDefaults {
      seedRememberedConfig()
      await resolveDraftModelSettingsIfNeeded()
    } else {
      await restoreModelSettings(forModel: value, harnessId: harnessId, revision: revision)
    }
  }

  private func clearDraftModelSettings(harnessId: String) {
    for option in configOptions where Self.isModelSetting(option) {
      pendingConfiguration.removeValue(for: option.id, in: harnessId)
    }
  }

  private func restoreModelSettings(forModel modelValue: String, harnessId: String, revision: UInt64) async {
    let remembered = rememberedConfigSelections(forHarness: harnessId, model: modelValue)
    let defaults = await defaultSettings(forModel: modelValue, harnessId: harnessId, unlessCoveredBy: remembered)
    guard modelPickRevision == revision else { return }

    for option in configOptions where Self.isModelSetting(option) {
      guard let target = Self.firstOffered([remembered[option.id], defaults[option.id]], by: option),
        target != option.currentValue
      else { continue }
      await setConfigOption(option.id, target)
      guard modelPickRevision == revision else { return }
    }
  }

  private func defaultSettings(
    forModel modelValue: String,
    harnessId: String,
    unlessCoveredBy remembered: [String: String]
  ) async -> [String: String] {
    let needsDefaults = configOptions.filter(Self.isModelSetting).contains { option in
      Self.firstOffered([remembered[option.id]], by: option) == nil
    }
    guard needsDefaults, let client = serverClient,
      let response = try? await client.capabilities(
        cwd: capabilityCwd,
        harnessId: harnessId,
        configSelections: [modelConfigId(forHarness: harnessId): modelValue]
      ),
      let capability = response.harnesses.first(where: { $0.harness.id == harnessId }),
      Self.modelOption(in: capability.configOptions)?.currentValue == modelValue
    else { return [:] }
    let defaults = capability.configOptions.filter(Self.isModelSetting).map { ($0.id, $0.currentValue) }
    return Dictionary(defaults) { first, _ in first }
  }

  private static func firstOffered(_ candidates: [String?], by option: SessionConfigOption) -> String? {
    candidates.compactMap { $0 }.first { candidate in
      option.options.contains { $0.value == candidate }
    }
  }
}
